#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Conv1 阵列金标准生成器（纯整数）

输入：
  tb/conv1_weights.txt        （由 gen_conv1_weights.py 生成）
输出：
  tb/conv1_in.hex             NF*T 行，每行 128 bit 输入脉冲向量（32 hex）
  tb/conv1_spike_exp.hex      NF*C*T 行，每行 128 bit 期望输出（32 hex）
                             顺序 = 帧 → 通道 → 时间步（与 RTL 输出流一致）

逐位模型（与 rtl/conv1_array.v + lif_neuron 契约一致）：
  x[c][j] = b[c] + Σ_{k=0..4} W[c][k] · s[t][j+k-2]     （越界补 0）
  v       = sat16(v + x)
  spike   = (v >= th[c])
  v       = spike ? v - th[c] : v

测试帧刻意覆盖：
  · 全 0 / 全 1（偏置驱动 / 满驱动）
  · 单个脉冲走过边界 0,1,2 / 63,64（两组交界）/ 125,126,127
  · 1010 / 0101 交替
  · 前 8 步静默、后 8 步全 1（时间累积）
  · 稀疏 / 密集 / 一般随机
  · 交替在位置 0 和 127 打单点（两端 pad）
"""

import os
import random

N, T, C, K = 128, 16, 8, 5
VMAX, VMIN = 32767, -32768

here = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# 读权重
# ---------------------------------------------------------------------------
W = [[0] * K for _ in range(C)]
B = [0] * C
TH = [0] * C

with open(os.path.join(here, "conv1_weights.txt")) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split()
        if p[0] == "W":
            W[int(p[1])][int(p[2])] = int(p[3])
        elif p[0] == "B":
            B[int(p[1])] = int(p[2])
        elif p[0] == "T":
            TH[int(p[1])] = int(p[2])
        else:
            raise ValueError(f"未知行: {line}")

assert all(t >= 1 for t in TH), "阈值必须 >= 1"


# ---------------------------------------------------------------------------
# 测试帧
# ---------------------------------------------------------------------------
ALL1 = (1 << N) - 1
FRAMES = []


def add(name, vecs):
    assert len(vecs) == T
    assert all(0 <= v <= ALL1 for v in vecs)
    FRAMES.append((name, vecs))


add("zero", [0] * T)
add("all_one", [ALL1] * T)

walk = [0] * T
for t, p in enumerate([0, 1, 2, 63, 64, 65, 126, 127, 31, 32, 95, 96, 15, 47, 79, 111]):
    walk[t] = 1 << p
add("single_walk", walk)

add("alt10", [sum(1 << i for i in range(0, N, 2))] * T)
add("alt01", [sum(1 << i for i in range(1, N, 2))] * T)
add("burst", [0] * 8 + [ALL1] * 8)

rng = random.Random(20261018)


def rand_vec(p):
    return sum((1 << i) for i in range(N) if rng.random() < p)


add("sparse_rand", [rand_vec(0.05) for _ in range(T)])
add("dense_rand", [rand_vec(0.50) for _ in range(T)])
add("mid_rand", [rand_vec(0.20) for _ in range(T)])
add("edge_repeat", [(1 << 0) if t % 2 == 0 else (1 << 127) for t in range(T)])

NF = len(FRAMES)
assert NF == 10, f"tb 里 NF 固定为 10，当前 {NF}"


# ---------------------------------------------------------------------------
# 整数金标准
# ---------------------------------------------------------------------------
def sat16(v):
    return max(VMIN, min(VMAX, v))


def run_conv1(frame):
    """返回 out[c][t] = 128-bit 发放向量。"""
    # 先把帧扩成带 pad 的比特串：pad[i+2] = s[i]
    padded = []
    for t in range(T):
        s = frame[t]
        padded.append([0, 0] + [((s >> i) & 1) for i in range(N)] + [0, 0])

    out = [[0] * T for _ in range(C)]
    for c in range(C):
        v = [0] * N
        for t in range(T):
            bits = 0
            p = padded[t]
            for j in range(N):
                x = B[c]
                for k in range(K):
                    if p[j + k]:
                        x += W[c][k]
                vv = sat16(v[j] + x)
                sp = 1 if vv >= TH[c] else 0
                if sp:
                    vv -= TH[c]
                v[j] = vv
                if sp:
                    bits |= (1 << j)
            out[c][t] = bits
    return out


results = []
for name, frame in FRAMES:
    results.append(run_conv1(frame))

# 自检锚点（与具体权重数值无关，占位/真实权重都成立）：
#   1) 每个输出都在 128 位范围内（结构正确性）
#   2) 全 1 与全 0 输入的输出不同（权重确实参与了运算）
#   3) 至少有一次发放，判分台才能覆盖到 LIF 发放路径
for fr in results:
    for ch in fr:
        for b in ch:
            assert 0 <= b < (1 << N), b
assert results[1] != results[0], "全 1 与全 0 输入不应得到完全相同的输出"
total = sum(bin(b).count("1") for fr in results for ch in fr for b in ch)
assert total > 0, "所有帧都没有发放，权重/模型可疑"

# ---------------------------------------------------------------------------
# 写 hex
# ---------------------------------------------------------------------------
with open(os.path.join(here, "conv1_in.hex"), "w") as f:
    for _, frame in FRAMES:
        for v in frame:
            f.write(f"{v:032x}\n")

with open(os.path.join(here, "conv1_spike_exp.hex"), "w") as f:
    for fr in results:
        for c in range(C):
            for t in range(T):
                f.write(f"{fr[c][t]:032x}\n")

print(f"生成 Conv1 向量：{NF} 帧 x {T} 步 -> tb/conv1_in.hex, tb/conv1_spike_exp.hex")
print(f"参考模型总发放数：{total} / {NF*C*T*N} 个神经元-步")
for (name, _), fr in zip(FRAMES, results):
    nz = sum(bin(b).count("1") for ch in fr for b in ch)
    print(f"  {name:<12s} 发放 {nz:6d}")
