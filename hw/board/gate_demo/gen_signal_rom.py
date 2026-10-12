#!/usr/bin/env python3
"""生成上板 demo 用的"真实常规脉冲"ROM（signal_rom.v）。

为什么要它：gate_demo 之前用方波（din=80/0）当活动场景，太假。这里换成
**项目自己的雷达信号库**生成的一段真常规脉冲（Pulse），走和训练/部署**同一条
预处理链**（加噪 → 零均值单位方差标准化），再按 M6 定点约定量化成 din：

    x   = 标准化后的样本        （和模型输入同域）
    din = round(clip(x, -4, 4) * 16)        ← 1 LSB = 1/16，和 M6 编码器一致
    （M6 编码器：x = din/16，再 clamp 到 ±4 —— 所以 din 上限 ±64 就是满量程）

truth = 脉冲窗内（样本 i0..i1-1）→ 驱动侧真值，顶层拿它和检测器 active 做 A/B 对照。

产出的 signal_rom.v 是纯组合 case（yosys/nextpnr 都能综合），不依赖 $readmemh。

用法：
    cd /home/jierui/fpga_contest
    /home/jierui/miniconda3/bin/python hw/board/gate_demo/gen_signal_rom.py
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SIGNALS = os.path.abspath(os.path.join(HERE, '..', '..', '..', 'src', 'signals'))
sys.path.insert(0, SIGNALS)

import radar_signal as rs   # noqa: E402

# ---- 信号参数（题目定：常规脉冲 tau=0.3；SNR=20dB）----
FS      = 10e6
N       = 128          # 和 dataset.py 的 N_POINTS 一致
SNR_DB  = 20.0
SEED    = 0
FC      = 2.0e6        # 载频
TAU     = 0.30         # 脉宽占比
T0      = 0.20         # 脉冲起始占比

SCALE   = 16.0         # din = x * SCALE
X_CLAMP = 4.0          # M6 编码器对 x 的钳位
W       = 16           # activity_detector 的窗长（样本数）


def quantize(x):
    """标准化样本 → M6 定点 din（有符号 8 位，落在编码器量程 ±64 内）。"""
    d = np.round(np.clip(x, -X_CLAMP, X_CLAMP) * SCALE).astype(int)
    return np.clip(d, -64, 64)


def parse_args():
    ap = argparse.ArgumentParser(description='生成上板 demo 的常规脉冲 ROM (signal_rom.v)')
    ap.add_argument('--snr', type=float, default=SNR_DB, help='信噪比 dB（默认 %(default)s）')
    ap.add_argument('--seed', type=int, default=SEED, help='随机种子（默认 %(default)s）')
    return ap.parse_args()


def main():
    args = parse_args()
    snr = args.snr
    clean, noisy, params = rs.generate_signal(
        'Pulse', FS, N, snr, seed=args.seed, fc=FC, tau=TAU, t0=T0)

    # 与 dataset.add_noise 同款预处理：零均值 + 单位方差
    x = noisy - noisy.mean()
    x = x / x.std()

    din = quantize(x)

    # 脉冲窗 [i0, i1)
    i0 = int(round(T0 * N))
    i1 = min(i0 + int(round(TAU * N)), N)
    truth = np.zeros(N, dtype=int)
    truth[i0:i1] = 1

    # 非重叠窗能量（W 个样本求和），看激活窗 / 静息窗的能量分布
    sums = [int(np.abs(din[i:i + W]).sum()) for i in range(0, N, W)]
    in_burst = [(k, s) for k, s in enumerate(sums)
                if truth[k * W:(k + 1) * W].all()]
    in_idle = [(k, s) for k, s in enumerate(sums)
               if not truth[k * W:(k + 1) * W].any()]
    mixed = [(k, s) for k, s in enumerate(sums)
             if (k, s) not in in_burst and (k, s) not in in_idle]

    print(f'Pulse 参数: {params}')
    print(f'脉冲窗: 样本 [{i0}, {i1})  共 {i1 - i0} 点')
    print(f'din 范围: [{din.min()}, {din.max()}]')
    print()
    print('窗序号 : 窗和   (W=%d)' % W)
    for k, s in enumerate(sums):
        tag = ' burst' if (k, s) in in_burst else (' idle' if (k, s) in in_idle else ' mixed')
        print(f'  {k:2d}   : {s:5d}  {tag}')
    print()
    print(f'纯激活窗和: {sorted(s for _, s in in_burst)}')
    print(f'纯静息窗和: {sorted(s for _, s in in_idle)}')
    print(f'混合窗和  : {sorted(s for _, s in mixed)}')

    # ---- 阈值：夹在"最大静息窗"与"最小激活窗"之间 ----
    max_idle = max((s for _, s in in_idle), default=0)
    min_burst = min((s for _, s in in_burst), default=1)
    print()
    print(f'建议阈值: TH_ON < {min_burst}, TH_OFF > {max_idle}（留裕量）')
    print(f'SUMMARY snr={snr:g} idle_max={max_idle} burst_min={min_burst} '
          f'mixed={sorted(s for _, s in mixed)}')

    # ---- 产出 signal_rom.v ----
    lines = []
    lines.append('// 本文件由 gen_signal_rom.py 自动生成，请勿手改。')
    lines.append(f'// 常规脉冲 Pulse: fc={FC/1e6:.1f}MHz tau={TAU:.2f} t0={T0:.2f} '
                 f'SNR={snr:g}dB, {N} 点 @{FS/1e6:.0f}MHz')
    lines.append(f'// 预处理: 零均值单位方差 → din = round(clip(x,-4,4)*16)，范围 [%d,%d]'
                 % (din.min(), din.max()))
    lines.append(f'// truth = 脉冲窗样本 [{i0},{i1}) = 该激活')
    lines.append('// 地址 addr 0..%d 循环播放，每拍给一个样本（din_valid 由顶层按分频给）。'
                 % (N - 1))
    lines.append('module signal_rom (')
    lines.append('  input  wire [6:0]        addr,')
    lines.append('  output reg  signed [7:0] din,')
    lines.append('  output reg               truth')
    lines.append(');')
    lines.append("  // din/truth 初值: 避免 addr=0 在仿真里读出 x (组合 case 的 delta-cycle 读前态),")
    lines.append("  // 会污染检测器第一窗 (win_sum=x) → nf 走错分支. 上板有 GSR 初值, 但仿真必须显式给.")
    lines.append("  initial begin din = 8'sd0; truth = 1'b0; end")
    lines.append('  always @(*) begin')
    lines.append('    case (addr)')
    for i in range(N):
        d = int(din[i]) & 0xFF
        lines.append(f"      7'd{i:<3d}: begin din = 8'h{d:02X}; truth = 1'b{truth[i]}; end")
    lines.append(f"      default: begin din = 8'h00; truth = 1'b0; end")
    lines.append('    endcase')
    lines.append('  end')
    lines.append('endmodule')

    out = os.path.join(HERE, 'signal_rom.v')
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'\n已写出 {out}')


if __name__ == '__main__':
    main()
