# -*- coding: utf-8 -*-
"""
demo_generate.py —— 雷达信号生成库 演示脚本（Day 1）
======================================================
运行：python3 demo_generate.py

功能：
  1. 生成 5 类信号，各出"时域 + 时频"图 → figures/
  2. 展示不同 SNR（20/0/-5 dB）下同一信号的效果对比
  3. 生成一个示例数据集，保存 npy → samples/
  4. 打印各类信号的随机参数（证明"每类随机参数"）
"""
import os
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use('Agg')          # 无显示环境也出图
import matplotlib.pyplot as plt

# 让本目录能 import 到 src/signals 下的信号生成库
_SIGNALS = str(Path(__file__).resolve().parent.parent / 'src' / 'signals')
if _SIGNALS not in sys.path:
    sys.path.insert(0, _SIGNALS)

import radar_signal as rs

FS = 10e6
N_POINTS = 1024

# 目录
os.makedirs('figures', exist_ok=True)
os.makedirs('samples', exist_ok=True)


def main():
    print('=' * 60)
    print('1. 生成 5 类信号并出图（SNR=10dB）')
    print('=' * 60)
    saved = rs.plot_5types(fs=FS, n_points=N_POINTS, snr_db=10,
                           out_dir='figures')
    for p in saved:
        print('  图:', p)

    print()
    print('=' * 60)
    print('2. 不同 SNR 对比（以 LFM 为例：20 / 0 / -5 dB）')
    print('=' * 60)
    fig, axes = plt.subplots(3, 1, figsize=(10, 8))
    for idx, snr in enumerate([20, 0, -5]):
        clean, noisy, params = rs.generate_signal('LFM', fs=FS,
                                                  n_points=N_POINTS,
                                                  snr_db=snr)
        axes[idx].plot(noisy, lw=0.6)
        axes[idx].set_title(f'LFM  SNR={snr} dB')
        axes[idx].grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig('figures/LFM_snr_compare.png', dpi=150)
    plt.close(fig)
    print('  图: figures/LFM_snr_compare.png')

    print()
    print('=' * 60)
    print('3. 随机参数示例（每类取 3 个样本看参数分布）')
    print('=' * 60)
    for sig_type in rs.SIGNAL_TYPES:
        print(f'\n--- {sig_type} ---')
        for i in range(3):
            _, _, params = rs.generate_signal(sig_type, fs=FS,
                                              n_points=N_POINTS, snr_db=10)
            # 精简打印：只显示关键标量参数
            brief = {k: (v if not isinstance(v, np.ndarray)
                         else f'数组len={len(v)}')
                     for k, v in params.items()}
            print(f'  样本{i}: {brief}')

    print()
    print('=' * 60)
    print('4. 生成示例数据集并保存 npy')
    print('=' * 60)
    X, y = rs.generate_dataset(fs=FS, n_points=N_POINTS,
                               n_per_class=50, snr_db=10, seed=0)
    np.save('samples/demo_X.npy', X)
    np.save('samples/demo_y.npy', y)
    print(f'  X.shape={X.shape}  y.shape={y.shape}')
    print(f'  y 类别计数: {np.bincount(y)}')
    print('  已保存: samples/demo_X.npy, samples/demo_y.npy')

    print()
    print('验收核对：')
    print('  [x] 5 类信号可生成')
    print('  [x] 每类参数随机')
    print('  [x] 任意 SNR 加噪（20/0/-5dB）')
    print('  [x] 时域 + 时频图输出正常')
    print('  [x] 数据集批量生成 + npy 保存')


if __name__ == '__main__':
    main()
