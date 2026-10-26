#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""引擎顶层端到端金标准生成器（纯整数）

输入：
  tb/conv1_weights.txt / tb/conv2_weights.txt / tb/fc1_weights.txt
  （占位权重或 src/export/export_int8.py 的真实导出权重都兼容，只认文本格式）
输出：
  tb/engine_smp.hex          NF*N 行，每行 2 hex 数字（8 位有符号 din 的补码）
  tb/engine_cls_exp.hex      NF 行，每行 1 hex 数字（argmax 类别）
  tb/engine_logits_exp.hex   NF 行，每行 25 hex 数字（5 × 20 bit，c=0 在最低 20 位）

逐位模型（与 rtl/encode_frontend.v + 四级阵列 + readout 契约一致）：
  din → n = clamp(((din+4) >>> 3) + T/2, 0, T)          // sample_to_n
  ΣΔ：acc += n; spike = acc >= T; acc -= T*spike          // 16 步
  Conv1：5 抽头、pad=2，v= sat16(v+x)，>=th 发放并软复位
  OR 池化 128→64；Conv2：16×8×5；OR 池化 64→32
  FC1：512→32（flatten c = o*32+j），LIF3
  readout：class = argmax_c ( Σ_r W[c,r]*count[r] + B[c]*T )（平局取小索引）
"""

import math
import os
import random

N, T = 128, 16
C1, K = 8, 5
CI2, CO2, NP2 = 8, 16, 64
NP3, NR, NC = 32, 32, 5
VMAX, VMIN = 32767, -32768
LW = 20

here = os.path.dirname(os.path.abspath(__file__))


def load_conv1(path):
    W = [[0] * K for _ in range(C1)]
    B = [0] * C1
    TH = [0] * C1
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            p = line.split()
            if p[0] == 'W':
                W[int(p[1])][int(p[2])] = int(p[3])
            elif p[0] == 'B':
                B[int(p[1])] = int(p[2])
            elif p[0] == 'T':
                TH[int(p[1])] = int(p[2])
            else:
                raise ValueError(f'未知行: {line}')
    return W, B, TH


def load_conv2(path):
    W = [[[0] * K for _ in range(CI2)] for _ in range(CO2)]
    B = [0] * CO2
    TH = [0] * CO2
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            p = line.split()
            if p[0] == 'W':
                W[int(p[1])][int(p[2])][int(p[3])] = int(p[4])
            elif p[0] == 'B':
                B[int(p[1])] = int(p[2])
            elif p[0] == 'T':
                TH[int(p[1])] = int(p[2])
            else:
                raise ValueError(f'未知行: {line}')
    return W, B, TH


def load_fc(path):
    W1 = [[0] * (CO2 * NP3) for _ in range(NR)]
    B1 = [0] * NR
    TH1 = [0] * NR
    W2 = [[0] * NR for _ in range(NC)]
    B2 = [0] * NC
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            p = line.split()
            if p[0] == 'W1':
                W1[int(p[1])][int(p[2])] = int(p[3])
            elif p[0] == 'B1':
                B1[int(p[1])] = int(p[2])
            elif p[0] == 'T1':
                TH1[int(p[1])] = int(p[2])
            elif p[0] == 'W2':
                W2[int(p[1])][int(p[2])] = int(p[3])
            elif p[0] == 'B2':
                B2[int(p[1])] = int(p[2])
            else:
                raise ValueError(f'未知行: {line}')
    return W1, B1, TH1, W2, B2


W1, B1, TH1 = load_conv1(os.path.join(here, 'conv1_weights.txt'))
W2, B2, TH2 = load_conv2(os.path.join(here, 'conv2_weights.txt'))
W3, B3, TH3, W4, B4 = load_fc(os.path.join(here, 'fc1_weights.txt'))

assert all(t >= 1 for t in TH1)
assert all(t >= 1 for t in TH2)
assert all(t >= 1 for t in TH3)


# ---------------------------------------------------------------------------
# 编码前端（与 sample_to_n + ΣΔ 逐位一致）
# ---------------------------------------------------------------------------
def sample_n(din):
    tmp = ((din + 4) >> 3) + T // 2      # Python >> 对负数是算术右移
    return max(0, min(T, tmp))


def encode(din_frame):
    n = [sample_n(d) for d in din_frame]
    acc = [0] * N
    out = []
    for _ in range(T):
        step = [0] * N
        for i in range(N):
            acc[i] += n[i]
            if acc[i] >= T:
                step[i] = 1
                acc[i] -= T
        out.append(step)
    return out


def sat16(x, stats):
    if x < VMIN or x > VMAX:
        stats[0] += 1
    return max(VMIN, min(VMAX, x))


def conv1_step(s, v, stats):
    """s/v: C1 × N。返回下一步 v、本步脉冲。"""
    spk = [[0] * N for _ in range(C1)]
    for c in range(C1):
        w = W1[c]
        for j in range(N):
            x = B1[c]
            for k in range(K):
                p = j + k - 2
                if 0 <= p < N and s[p]:
                    x += w[k]
            vv = sat16(v[c][j] + x, stats)
            if vv >= TH1[c]:
                spk[c][j] = 1
                v[c][j] = vv - TH1[c]
            else:
                v[c][j] = vv
    return spk


def conv2_step(s, v, stats):
    """s: CI2 × NP2（池化后），v: CO2 × NP2。"""
    spk = [[0] * NP2 for _ in range(CO2)]
    for o in range(CO2):
        for j in range(NP2):
            x = B2[o]
            for i in range(CI2):
                w = W2[o][i]
                for k in range(K):
                    p = j + k - 2
                    if 0 <= p < NP2 and s[i][p]:
                        x += w[k]
            vv = sat16(v[o][j] + x, stats)
            if vv >= TH2[o]:
                spk[o][j] = 1
                v[o][j] = vv - TH2[o]
            else:
                v[o][j] = vv
    return spk


def pool(s):
    """(C, 2M) → (C, M)：OR 相邻两列。"""
    return [[s[c][2 * j] | s[c][2 * j + 1] for j in range(len(s[0]) // 2)]
            for c in range(len(s))]


def forward(din_frame):
    """一帧 din[128] → (class, logits[5], stats)。"""
    steps = encode(din_frame)
    v1 = [[0] * N for _ in range(C1)]
    v2 = [[0] * NP2 for _ in range(CO2)]
    v3 = [0] * NR
    count = [0] * NR
    stats = {'conv1': [0], 'conv2': [0], 'fc1': [0]}

    for t in range(T):
        # Conv1 + 池化 128→64
        s1 = conv1_step(steps[t], v1, stats['conv1'])
        p1 = pool(s1)
        # Conv2 + 池化 64→32
        s2 = conv2_step(p1, v2, stats['conv2'])
        p2 = pool(s2)
        # FC1（flatten c = o*32+j）
        flat = [p2[o][j] for o in range(CO2) for j in range(NP3)]
        for r in range(NR):
            x = B3[r]
            wr = W3[r]
            for c in range(CO2 * NP3):
                if flat[c]:
                    x += wr[c]
            vv = sat16(v3[r] + x, stats['fc1'])
            if vv >= TH3[r]:
                count[r] += 1
                v3[r] = vv - TH3[r]
            else:
                v3[r] = vv

    logits = [sum(W4[c][r] * count[r] for r in range(NR)) + B4[c] * T
              for c in range(NC)]
    best_c, best = 0, logits[0]
    for c in range(1, NC):                 # > ：平局取小索引
        if logits[c] > best:
            best_c, best = c, logits[c]
    return best_c, logits, stats


# ---------------------------------------------------------------------------
# 测试帧（din 空间，8 位有符号；±64 = 训练端 ±4 的 clamp 端）
# ---------------------------------------------------------------------------
def clamp_din(v):
    return max(-64, min(63, int(round(v))))


FRAMES = []


def add(name, din):
    assert len(din) == N
    FRAMES.append((name, [clamp_din(v) for v in din]))


add('zero', [0] * N)
add('full_pos', [64] * N)
add('full_neg', [-64] * N)
add('pair_alt', [64 if (i // 2) % 2 == 0 else -64 for i in range(N)])
add('ramp', [-64 + i for i in range(N)])

rng = random.Random(20251023)
add('random', [rng.randint(-64, 63) for _ in range(N)])
add('pulse', [0] * 30 + [64] * 20 + [0] * (N - 50))
add('lfm', [clamp_din(48 * math.sin(0.02 * i * i)) for i in range(N)])
add('small_rand', [rng.randint(-12, 12) for _ in range(N)])


# ---------------------------------------------------------------------------
# 自检锚点
# ---------------------------------------------------------------------------
# 编码器的五个规格点（与 sample_to_n.v 头注释一致）
assert sample_n(0) == 8
assert sample_n(32) == 12
assert sample_n(64) == 16
assert sample_n(-64) == 0
assert sample_n(127) == 16

# 全零样本（din=0 → n=8）应得到 0,1,0,1,… 的 ΣΔ 图案
zero_steps = encode([0] * N)
assert all(v == 0 for v in zero_steps[0])
assert all(v == 1 for v in zero_steps[1])
assert all(v == 0 for v in zero_steps[2])

results = [(name, *forward(din)) for name, din in FRAMES]
classes = [r[1] for r in results]

assert len(FRAMES) >= 5
assert len(set(classes)) >= 2, f'测试帧类别太单一: {classes}'
assert all(0 <= c < NC for c in classes)
for name, _, logits, stats in results:
    assert all(-(1 << (LW - 1)) <= lg < (1 << (LW - 1)) for lg in logits), name
    assert all(v[0] == 0 for v in stats.values()), f'{name} 出现 16 位饱和 {stats}'


# ---------------------------------------------------------------------------
# 写向量
# ---------------------------------------------------------------------------
with open(os.path.join(here, 'engine_smp.hex'), 'w') as f:
    for _, din in FRAMES:
        for d in din:
            f.write(f'{d & 0xFF:02x}\n')

with open(os.path.join(here, 'engine_cls_exp.hex'), 'w') as f:
    for c in classes:
        f.write(f'{c:x}\n')

with open(os.path.join(here, 'engine_logits_exp.hex'), 'w') as f:
    for _, _, logits, _ in results:
        f.write(''.join(f'{lg & ((1 << LW) - 1):05x}' for lg in reversed(logits)) + '\n')

print(f'引擎顶层向量已生成：{len(FRAMES)} 帧')
print(f'  {"frame":<12} {"class":>5}  logits')
for name, cls, logits, _ in results:
    print(f'  {name:<12} {cls:>5}  {logits}')
print(f'  类别覆盖: {sorted(set(classes))}')
