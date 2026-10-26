#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FC1 + 读出层金标准生成器（纯整数）

输入：
  tb/fc1_weights.txt          （由 gen_fc1_weights.py 生成）
输出：
  tb/fc_in.hex                NF*CI*T 行，每行 64 bit 输入脉冲向量（16 hex）
                              顺序 = 帧 → 输入通道 → 时间步（与 Conv2 输出流一致）
  tb/fc_spike_exp.hex         NF*T 行，每行 32 bit FC1/LIF3 期望脉冲（8 hex）
                              顺序 = 帧 → 时间步
  tb/fc_class_exp.hex         NF 行，每行 1 hex 数字（argmax 类别）
  tb/fc_logits_exp.hex        NF 行，每行 25 hex 数字（5 × 20 bit，c=0 在最低 20 位）

逐位模型（与 rtl/fc1_array.v + rtl/readout.v 契约一致）：
  p[t][o][j] = in[t][o][2j] | in[t][o][2j+1]                  （OR 池化 64→32）
  c          = o*32 + j                                       （PyTorch flatten 序）
  x[r]       = B1[r] + Σ_c W1[r][c] · p[t][o=c>>5][j=c&31]
  v          = sat16(v + x)
  spike[r]   = (v >= TH1[r])
  v          = spike ? v - TH1[r] : v
  logits[c]  = Σ_r W2[c][r] · count[r] + B2[c] · T
  class      = argmax_c logits[c]（平局取最小索引，与 PyTorch 一致）

测试帧刻意覆盖：
  · 全 0 / 全 1（零帧顺带验证"平局取小索引"：B2[3]==B2[4] 最大）
  · 单脉冲走过池化边界 0/1/2/3/30/31/32/33/62/63
  · 只打偶数位 / 只打奇数位（池化后都应为全 1 → 两帧输出必须相同）
  · 成对设置（两个相邻位同时为 1，验证 OR 不是加法）
  · 前 8 步静默、后 8 步全 1（时间累积）
  · 稀疏 / 密集 / 中等随机
  · 两端交替（位置 0 / 63）
"""

import os
import random

NPIN, NP, T, CI = 64, 32, 16, 16
NR, NIN, NC = 32, 512, 5
VMAX, VMIN = 32767, -32768
LW = 20                          # 读出层累加器位宽（与 rtl/readout.v 一致）

here = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# 读权重
# ---------------------------------------------------------------------------
W1 = [[0] * NIN for _ in range(NR)]
B1 = [0] * NR
TH1 = [0] * NR
W2 = [[0] * NR for _ in range(NC)]
B2 = [0] * NC

with open(os.path.join(here, "fc1_weights.txt")) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split()
        if p[0] == "W1":
            W1[int(p[1])][int(p[2])] = int(p[3])
        elif p[0] == "B1":
            B1[int(p[1])] = int(p[2])
        elif p[0] == "T1":
            TH1[int(p[1])] = int(p[2])
        elif p[0] == "W2":
            W2[int(p[1])][int(p[2])] = int(p[3])
        elif p[0] == "B2":
            B2[int(p[1])] = int(p[2])
        else:
            raise ValueError(f"未知行: {line}")

assert all(t >= 1 for t in TH1), "阈值必须 >= 1"
assert all(-128 <= w <= 127 for row in W1 for w in row)
assert all(-128 <= w <= 127 for row in W2 for w in row)


# ---------------------------------------------------------------------------
# 测试帧（每帧 = CI*T 个 64-bit 向量，顺序 o 优先 / t 次之，与 Conv2 输出一致）
# ---------------------------------------------------------------------------
ALL1 = (1 << NPIN) - 1
FRAMES = []


def bits(positions):
    return sum(1 << p for p in positions)


def frame_from(fn):
    """fn(o, t) -> 64-bit int"""
    return [fn(o, t) for o in range(CI) for t in range(T)]


def add(name, vecs):
    assert len(vecs) == CI * T
    assert all(0 <= v <= ALL1 for v in vecs)
    FRAMES.append((name, vecs))


add("zero", [0] * (CI * T))
add("all_one", [ALL1] * (CI * T))

# 单点走边界：0/1/2/3 覆盖第一个池化对，30/31/32/33 覆盖组边界（c=o*32+j），
# 62/63 覆盖最后一对；在 256 个 (通道,步) 上轮转
POS_WALK = [0, 1, 2, 3, 30, 31, 32, 33, 62, 63, 15, 16, 47, 48]
walk = frame_from(lambda o, t: 1 << POS_WALK[(o * T + t) % len(POS_WALK)])
add("single_walk", walk)

EVEN = bits(range(0, NPIN, 2))
ODD = bits(range(1, NPIN, 2))
add("alt_even", [EVEN] * (CI * T))
add("alt_odd", [ODD] * (CI * T))

# 成对设置：每对两个位置都为 1，池化后仍是 1（OR 不是加法）
PAIRS = bits([p for j in range(0, NP, 3) for p in (2 * j, 2 * j + 1)])
add("pairs", [PAIRS] * (CI * T))

add("burst", frame_from(lambda o, t: 0 if t < 8 else ALL1))

rng = random.Random(20261021)


def rand_vec(p):
    return sum((1 << i) for i in range(NPIN) if rng.random() < p)


add("sparse_rand", frame_from(lambda o, t: rand_vec(0.05)))
add("dense_rand", frame_from(lambda o, t: rand_vec(0.50)))
add("mid_rand", frame_from(lambda o, t: rand_vec(0.20)))

add("edge_repeat", frame_from(
    lambda o, t: (1 << 0) if t % 2 == 0 else (1 << (NPIN - 1))))

NF = len(FRAMES)
assert NF == 11, f"tb 里 NF 固定为 11，当前 {NF}"


# ---------------------------------------------------------------------------
# 整数金标准
# ---------------------------------------------------------------------------
def sat16(v):
    return max(VMIN, min(VMAX, v))


def pool(vec):
    """64 bit → 32 bit：相邻两位相或。"""
    return [((vec >> (2 * j)) & 1) | ((vec >> (2 * j + 1)) & 1)
            for j in range(NP)]


def run_fc(frame):
    """返回 (spikes[T] 每步 32-bit, counts[NR], logits[NC], class, sat_r[NR])。"""
    # pooled[t][o][j]
    pooled = [[None] * CI for _ in range(T)]
    for t in range(T):
        for o in range(CI):
            pooled[t][o] = pool(frame[o * T + t])

    v = [0] * NR
    spikes = [0] * T
    counts = [0] * NR
    sat_r = [0] * NR
    for t in range(T):
        vec = 0
        for r in range(NR):
            x = B1[r]
            for o in range(CI):
                pp = pooled[t][o]
                base = o * NP
                for j in range(NP):
                    if pp[j]:
                        x += W1[r][base + j]
            vpre = v[r] + x
            if vpre < VMIN or vpre > VMAX:
                sat_r[r] += 1
            vv = sat16(vpre)
            sp = 1 if vv >= TH1[r] else 0
            if sp:
                vv -= TH1[r]
                vec |= (1 << r)
                counts[r] += 1
            v[r] = vv
        spikes[t] = vec

    logits = []
    for c in range(NC):
        acc = sum(W2[c][r] * counts[r] for r in range(NR)) + B2[c] * T
        logits.append(acc)
        assert -(1 << (LW - 1)) <= acc < (1 << (LW - 1)), \
            f"class {c} logit {acc} 超出 int{LW}"

    cls = 0
    for c in range(1, NC):
        if logits[c] > logits[cls]:          # 平局取小索引（与 PyTorch argmax 一致）
            cls = c
    return spikes, counts, logits, cls, sat_r


results = []
sat_total = 0
sat_r_total = [0] * NR
for name, frame in FRAMES:
    sp, cnt, lg, cl, sat_r = run_fc(frame)
    sat_total += sum(sat_r)
    sat_r_total = [a + b for a, b in zip(sat_r_total, sat_r)]
    results.append((sp, cnt, lg, cl))

# ---------------------------------------------------------------------------
# 自检锚点（与具体权重数值无关，占位/真实权重都成立）
# ---------------------------------------------------------------------------
# 1) 池化正确性：alt_even / alt_odd 池化后完全相同
assert results[3][0] == results[4][0], "even/odd 交替帧池化后应完全一致"

# 2) 全 1 与全 0 输入的结果不同（权重确实参与运算）
assert results[1][0] != results[0][0], "全 1 与全 0 输入不应得到完全相同的 FC1 输出"

# 3) 至少有一个非零帧，且类别覆盖不止一种
assert any(any(s != 0 for s in sp) for sp, _, _, _ in results)
assert len({cl for _, _, _, cl in results}) >= 2, "测试帧类别太单一，判分覆盖不足"

total_spk = sum(bin(s).count("1") for sp, _, _, _ in results for s in sp)
assert total_spk > 0
# 占位权重下饱和是**预期**的：输入电流远大于阈值时，软复位每步只减 TH，
# 膜电位会持续上漂/下漂到 ±32768（RTL 必须饱和而不是绕回）。
# 这里只把饱和数记进日志，实际由判分台逐位对拍（金标准同样做 sat16）。

# ---------------------------------------------------------------------------
# 写 hex
# ---------------------------------------------------------------------------
with open(os.path.join(here, "fc_in.hex"), "w") as f:
    for _, frame in FRAMES:
        for v in frame:
            f.write(f"{v:016x}\n")

with open(os.path.join(here, "fc_spike_exp.hex"), "w") as f:
    for sp, _, _, _ in results:
        for v in sp:
            f.write(f"{v:08x}\n")

with open(os.path.join(here, "fc_class_exp.hex"), "w") as f:
    for _, _, _, cl in results:
        f.write(f"{cl:x}\n")

with open(os.path.join(here, "fc_logits_exp.hex"), "w") as f:
    for _, _, lg, _ in results:
        word = 0
        for c in range(NC):
            word |= (lg[c] & ((1 << LW) - 1)) << (c * LW)
        f.write(f"{word:025x}\n")

print(f"生成 FC 向量：{NF} 帧 x {CI} 通道 x {T} 步 -> tb/fc_in.hex 等 4 个文件")
print(f"参考模型总发放数：{total_spk} / {NF*T*NR} 个神经元-步；饱和 {sat_total}")
for (name, _), (sp, cnt, lg, cl) in zip(FRAMES, results):
    nz = sum(bin(s).count("1") for s in sp)
    print(f"  {name:<12s} 发放 {nz:4d}  count和={sum(cnt):4d}  "
          f"logits={lg}  class={cl}")
