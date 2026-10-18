#!/usr/bin/env python3
"""生成 128 路编码前端判分台的金标准向量（frame.hex / golden.hex）。

金标准来源（沿用 M6 的规矩，不手抄公式）：
  · 每帧 128 个 din：有符号 8 位定点，x = din/16（M6/上板 ROM 同一约定）
  · n = 硬件定点规则 clamp(((din+4) >>> 3) + 8, 0, 16)   ← 与 M6 sample_to_n 完全一致
  · 16 步发放图案直接调用训练端编码器 snn_conv.encode_input(mode='spread')
    （用 x01 = n/T 的构造法，与 hw/verilog_lab/m6_encoder/gen_vectors.py 同一套），
    并断言它 == ΣΔ 累加器模型。

关于舍入 tie（din ≡ 4 mod 8）：
  训练端 torch.round 是银行家舍入，硬件 sample_to_n 是"加半 LSB 进上"，这些点会差 1 个
  脉冲（M6 题面已记录）。本判分台吃的是**硬件规格**，所以金标准跟随硬件整数规则；
  脚本会打印每帧有多少样本与训练端分歧，并专门放两帧纯 tie 数据（din=+4 / -12）锁死行为。

产出（与本脚本同目录）：
  frame.hex    NF*N 行，每行 2 位十六进制 = 一个有符号 8 位 din
  golden.hex   NF*T 行，每行 32 位十六进制 = 128 bit 脉冲向量（bit i = 第 i 个样本）

用法：
    cd /home/jierui/fpga_contest
    /home/jierui/miniconda3/bin/python hw/engine/gen_vectors.py
"""
import os
import sys

import numpy as np

T     = 16
N     = 128
INV   = 8.0             # 训练端 inv_scale
SCALE = 16.0            # 硬件定点：x = din / SCALE
X_CLAMP = 4.0           # din 量程 ±64

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src', 'models'))
sys.path.insert(0, os.path.join(ROOT, 'src', 'signals'))

import torch                     # noqa: E402
import snn_conv as S             # noqa: E402
import radar_signal as rs        # noqa: E402


def hw_n(din):
    """硬件规则：加半个 LSB 再算术右移，最后钳位到 [0,T]。"""
    return min(max(((int(din) + 4) >> 3) + T // 2, 0), T)


def sw_n(din):
    """训练端规则：round(clamp(x/8+0.5,0,1)*T)，银行家舍入。"""
    x01 = min(max(din / SCALE / INV + 0.5, 0.0), 1.0)
    return int(round(x01 * T))


def acc_pattern(n):
    """ΣΔ 累加器行为模型，bit t = 第 t 步是否发放。"""
    acc, pat = 0, 0
    for t in range(T):
        acc += n
        if acc >= T:
            pat |= 1 << t
            acc -= T
    return pat


def standardize(x):
    """dataset.add_noise 之后同款预处理：零均值 + 单位方差。"""
    x = x - x.mean()
    s = x.std()
    return x / s if s > 0 else np.zeros_like(x)


def quantize(x):
    """标准化样本 → M6 定点 din（有符号 8 位，±64 满量程）。"""
    return np.round(np.clip(x, -X_CLAMP, X_CLAMP) * SCALE).astype(int)


def build_frames():
    """返回 [(名字, 128 点 din), ...]。前 8 帧是定向边界，后 5 帧是真实雷达信号。"""
    frames = []

    frames.append(('zeros',   np.zeros(N, dtype=int)))
    frames.append(('max+',    np.full(N, 64, dtype=int)))
    frames.append(('max-',    np.full(N, -64, dtype=int)))
    frames.append(('alt±',    np.tile([-64, 64], N // 2)))
    frames.append(('ramp',    np.round(np.linspace(-64, 64, N)).astype(int)))
    # 舍入 tie 帧：+4 与训练端差 1 个脉冲；-12 也差；纯 tie 方便定位
    frames.append(('tie +4',  np.full(N, 4, dtype=int)))
    frames.append(('tie -12', np.full(N, -12, dtype=int)))
    rng = np.random.default_rng(0)
    frames.append(('rand',    rng.integers(-64, 65, N)))

    # 5 类真实信号：覆盖不同 SNR，走训练/部署同一条预处理链
    specs = [('Pulse', 20.0, 11), ('LFM', 10.0, 12), ('BPSK', 0.0, 13),
             ('FSK',  -5.0, 14), ('CW',  10.0, 15)]
    for cls, snr, seed in specs:
        _, noisy, _ = rs.generate_signal(cls, 10e6, N, snr_db=snr, seed=seed)
        frames.append((f'{cls} {snr:g}dB', quantize(standardize(noisy))))

    for name, d in frames:
        assert d.shape == (N,), name
        assert d.min() >= -64 and d.max() <= 64, name
    return frames


def main():
    # 图案表 n=0..T：让训练端编码器吐 x01 = n/T（inv_scale=1、x 抵消 +0.5）
    xs_n = torch.tensor([n / T - 0.5 for n in range(T + 1)],
                        dtype=torch.float32).view(-1, 1, 1)
    spk_n = S.encode_input(xs_n, T, mode='spread', inv_scale=1.0)
    pat = [sum(int(spk_n[t, n, 0, 0].item()) << t for t in range(T))
           for n in range(T + 1)]
    for n in range(T + 1):
        assert pat[n] == acc_pattern(n), f'n={n}: 训练端图案与累加器模型不符'

    frames = build_frames()
    nf = len(frames)

    frame_lines, golden_lines = [], []
    total_ties = 0

    print(f'{"frame":<12} {"din范围":>12} {"tie分歧":>7}  向量示例(step0 / step1)')
    for name, d in frames:
        ns = [hw_n(v) for v in d]

        # 逐位组装 16 个 128-bit 向量：bit i = 样本 i 在该步是否发放
        vecs = [0] * T
        for i, n in enumerate(ns):
            p = pat[n]
            for t in range(T):
                if (p >> t) & 1:
                    vecs[t] |= (1 << i)

        ties = sum(1 for v in d if hw_n(v) != sw_n(v))
        total_ties += ties
        print(f'{name:<12} [{d.min():4d},{d.max():4d}] {ties:7d}  '
              f'{vecs[0]:032x} / {vecs[1]:032x}')

        frame_lines += [f'{int(v) & 0xFF:02x}' for v in d]
        golden_lines += [f'{v:032x}' for v in vecs]

    with open(os.path.join(HERE, 'frame.hex'), 'w') as f:
        f.write('\n'.join(frame_lines) + '\n')
    with open(os.path.join(HERE, 'golden.hex'), 'w') as f:
        f.write('\n'.join(golden_lines) + '\n')

    print(f'\n  frame.hex  : {nf * N} 行（{nf} 帧 × {N} 样本）')
    print(f'  golden.hex : {nf * T} 行（{nf} 帧 × {T} 步 × {N} bit）')
    print(f'  舍入 tie 分歧样本总数：{total_ties}（金标准按硬件规则；M6 题面已记录该差异）')
    print('  OK: 金标准图案 == 训练端 encode_input == 累加器模型')


if __name__ == '__main__':
    main()
