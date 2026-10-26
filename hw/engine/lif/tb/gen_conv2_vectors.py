#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Conv2 阵列金标准生成器（纯整数）

输入：
  tb/conv2_weights.txt        （由 gen_conv2_weights.py 生成）
输出：
  tb/conv2_in.hex             NF*CI*T 行，每行 128 bit 输入脉冲向量（32 hex）
                              顺序 = 帧 → 输入通道 → 时间步（与 Conv1 输出流一致）
  tb/conv2_spike_exp.hex      NF*CO*T 行，每行 64 bit 期望输出（16 hex）
                              顺序 = 帧 → 输出通道 → 时间步

逐位模型（与 rtl/conv2_array.v + lif_neuron 契约一致）：
  p[t][i][j] = in[t][i][2j] | in[t][i][2j+1]                  （OR 池化 128→64）
  x[o][j]    = b[o] + Σ_{i,k} W[o][i][k] · p[t][i][j+k-2]     （越界补 0）
  v          = sat16(v + x)
  spike      = (v >= th[o])
  v          = spike ? v - th[o] : v

测试帧刻意覆盖：
  · 全 0 / 全 1（偏置驱动 / 满驱动）
  · 单脉冲走过池化边界 0/1/2/3/62/63/64/65/126/127
  · 只打偶数位 / 只打奇数位（池化后都应为全 1）
  · 成对设置（两个相邻位同时为 1，验证 OR 不是加法）
  · 前 8 步静默、后 8 步全 1（时间累积）
  · 稀疏 / 密集 / 中等随机
  · 两端交替（位置 0 / 127）
"""

import os
import random

NIN, NP, T, CI, CO, K = 128, 64, 16, 8, 16, 5
VMAX, VMIN = 32767, -32768

here = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# 读权重
# ---------------------------------------------------------------------------
W = [[[0] * K for _ in range(CI)] for _ in range(CO)]
B = [0] * CO
TH = [0] * CO

with open(os.path.join(here, "conv2_weights.txt")) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split()
        if p[0] == "W":
            W[int(p[1])][int(p[2])][int(p[3])] = int(p[4])
        elif p[0] == "B":
            B[int(p[1])] = int(p[2])
        elif p[0] == "T":
            TH[int(p[1])] = int(p[2])
        else:
            raise ValueError(f"未知行: {line}")

assert all(t >= 1 for t in TH), "阈值必须 >= 1"


# ---------------------------------------------------------------------------
# 测试帧（每帧 = CI*T 个 128-bit 向量，顺序 ic 优先 / t 次之）
# ---------------------------------------------------------------------------
ALL1 = (1 << NIN) - 1
FRAMES = []


def bits(positions):
    return sum(1 << p for p in positions)


def frame_from(fn):
    """fn(ic, t) -> 128-bit int"""
    return [fn(ic, t) for ic in range(CI) for t in range(T)]


def add(name, vecs):
    assert len(vecs) == CI * T
    assert all(0 <= v <= ALL1 for v in vecs)
    FRAMES.append((name, vecs))


add("zero", [0] * (CI * T))
add("all_one", [ALL1] * (CI * T))

# 单点走边界与池化对：同一个位置上 128 拍轮转
POS_WALK = [0, 1, 2, 3, 62, 63, 64, 65, 126, 127,
            31, 32, 33, 34, 95, 96]
walk = frame_from(lambda ic, t: 1 << POS_WALK[(ic * T + t) % len(POS_WALK)])
add("single_walk", walk)

EVEN = bits(range(0, NIN, 2))
ODD = bits(range(1, NIN, 2))
add("alt_even", [EVEN] * (CI * T))
add("alt_odd", [ODD] * (CI * T))

# 成对设置：每对两个位置都为 1，池化后仍是 1（OR 不是加法）
PAIRS = bits([p for j in range(0, NP, 3) for p in (2 * j, 2 * j + 1)])
add("pairs", [PAIRS] * (CI * T))

add("burst", frame_from(lambda ic, t: 0 if t < 8 else ALL1))

rng = random.Random(20261020)


def rand_vec(p):
    return sum((1 << i) for i in range(NIN) if rng.random() < p)


add("sparse_rand", frame_from(lambda ic, t: rand_vec(0.05)))
add("dense_rand", frame_from(lambda ic, t: rand_vec(0.50)))
add("mid_rand", frame_from(lambda ic, t: rand_vec(0.20)))

add("edge_repeat", frame_from(
    lambda ic, t: (1 << 0) if t % 2 == 0 else (1 << (NIN - 1))))

NF = len(FRAMES)
assert NF == 11, f"tb 里 NF 固定为 11，当前 {NF}"


# ---------------------------------------------------------------------------
# 整数金标准
# ---------------------------------------------------------------------------
def sat16(v):
    return max(VMIN, min(VMAX, v))


def pool(vec):
    """128 bit → 64 bit：相邻两位相或。"""
    return [((vec >> (2 * j)) & 1) | ((vec >> (2 * j + 1)) & 1)
            for j in range(NP)]


def run_conv2(frame):
    """返回 out[o][t] = 64-bit 发放向量。"""
    # padded[t][i][j+2] = pool(frame[t][i])[j]
    padded = [[None] * CI for _ in range(T)]
    for t in range(T):
        for i in range(CI):
            padded[t][i] = [0, 0] + pool(frame[i * T + t]) + [0, 0]

    out = [[0] * T for _ in range(CO)]
    for o in range(CO):
        v = [0] * NP
        for t in range(T):
            bits_out = 0
            for j in range(NP):
                x = B[o]
                for i in range(CI):
                    p = padded[t][i]
                    for k in range(K):
                        if p[j + k]:
                            x += W[o][i][k]
                vv = sat16(v[j] + x)
                sp = 1 if vv >= TH[o] else 0
                if sp:
                    vv -= TH[o]
                v[j] = vv
                if sp:
                    bits_out |= (1 << j)
            out[o][t] = bits_out
    return out


results = []
for name, frame in FRAMES:
    results.append(run_conv2(frame))

# ---------------------------------------------------------------------------
# 自检锚点（与具体权重数值无关，占位/真实权重都成立）
# ---------------------------------------------------------------------------
# 结构：每个输出都在 64 位范围内
for fr in results:
    for ch in fr:
        for b in ch:
            assert 0 <= b < (1 << NP), b

# 池化正确性：alt_even / alt_odd 两帧池化后完全相同，输出也必须完全相同
assert results[3] == results[4], "even/odd 交替帧池化后应完全一致"

# 全 1 与全 0 输入的结果不同（权重确实参与运算）
assert results[1] != results[0], "全 1 与全 0 输入不应得到完全相同的输出"

total = sum(bin(b).count("1") for fr in results for ch in fr for b in ch)
assert total > 0, "所有帧都没有发放，权重/模型可疑"

# ---------------------------------------------------------------------------
# 写 hex
# ---------------------------------------------------------------------------
with open(os.path.join(here, "conv2_in.hex"), "w") as f:
    for _, frame in FRAMES:
        for v in frame:
            f.write(f"{v:032x}\n")

with open(os.path.join(here, "conv2_spike_exp.hex"), "w") as f:
    for fr in results:
        for o in range(CO):
            for t in range(T):
                f.write(f"{fr[o][t]:016x}\n")

print(f"生成 Conv2 向量：{NF} 帧 x {CI} 输入通道 x {T} 步 "
      f"-> tb/conv2_in.hex, tb/conv2_spike_exp.hex")
print(f"参考模型总发放数：{total} / {NF*CO*T*NP} 个神经元-步")
for (name, _), fr in zip(FRAMES, results):
    nz = sum(bin(b).count("1") for ch in fr for b in ch)
    print(f"  {name:<12s} 发放 {nz:6d}")
