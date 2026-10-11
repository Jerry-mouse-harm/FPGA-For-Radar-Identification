# -*- coding: utf-8 -*-
"""
src/data/dataset.py —— Day2 数据集构建
========================================
- 5 类雷达信号（Pulse/LFM/BPSK/FSK/CW），每样本 128 点 @10MHz
- 训练集：多 SNR 混合（每个实例随机抽 -5~20dB 一个 SNR）
- 测试集：同一批信号实例，在 SNR_GRID 各档各加一遍噪声 → 用于"识别率-信噪比"曲线
- 训练/测试按【信号实例】切分：不同 seed 生成不同参数的实例，防止泄漏
- 每样本标准化（零均值、单位方差，不改变信噪比比值）

用法：
    import dataset
    X, y, snr = dataset.build_train_set(n_per_class=2000)          # (N,1,128)
    test_sets = dataset.build_test_sets(n_per_class=500)           # {snr: (X,y)}
"""
import os
import sys
from pathlib import Path

import numpy as np

# 让本目录能 import 到 src/signals 下的信号生成库
_SIGNALS = str(Path(__file__).resolve().parent.parent / 'signals')
if _SIGNALS not in sys.path:
    sys.path.insert(0, _SIGNALS)

import radar_signal as rs

SIGNAL_TYPES = rs.SIGNAL_TYPES
N_CLASSES = len(SIGNAL_TYPES)   # 5
FS = 10e6
N_POINTS = 128
SNR_GRID = [-5, 0, 5, 10, 15, 20]      # 评估用 SNR 档位
SNR_TRAIN_RANGE = (-5.0, 20.0)         # 训练 SNR 抽取范围（多 SNR 混合）


# ============================================================================
# 一、信号实例生成（按实例切分训练/测试，防泄漏）
# ============================================================================
def make_instances(n_per_class, seed=0, n_points=N_POINTS, fs=FS):
    """生成 n_per_class×5 个【干净】信号实例（固定参数、不加噪）。

    同一个实例可被多次加噪，因此先在实例层切分 train/test：
    train 用 seed=100，test 用 seed=200 → 参数实例完全不重叠。

    返回:
        cleans      : (N, n_points) float32 干净信号
        y           : (N,) int 类别索引 0~4
        params_list : 每个实例的参数 dict 列表
    """
    rng = np.random.default_rng(seed)
    cleans, ys, params_list = [], [], []
    for cls, sig_type in enumerate(SIGNAL_TYPES):
        for _ in range(n_per_class):
            clean, _, params = rs.generate_signal(sig_type, fs, n_points,
                                                  snr_db=None, rng=rng)
            cleans.append(clean.astype(np.float32))
            ys.append(cls)
            params_list.append(params)
    return np.stack(cleans), np.array(ys), params_list


def add_noise(clean, snr_db, rng, normalize=True):
    """单个实例：加 AWGN + 可选标准化。返回 (1, n_points) float32。
    标准化对整段信号统一缩放，不改变信号/噪声功率比。
    """
    noisy = rs.add_awgn(clean, snr_db, rng)
    if normalize:
        noisy = noisy - noisy.mean()
        std = noisy.std()
        if std > 1e-12:
            noisy = noisy / std
    return noisy[None, :].astype(np.float32)


# ============================================================================
# 二、训练集 / 测试集
# ============================================================================
def build_train_set(n_per_class=2000, seed_train=100, n_points=N_POINTS,
                    fs=FS, normalize=True, cache=None):
    """训练集：每个实例随机抽一个 SNR（SNR_TRAIN_RANGE 内均匀），多 SNR 混合。

    返回:
        X   : (N, 1, n_points) float32
        y   : (N,) int
        snr : (N,) float 每个样本对应的 SNR(dB)
    """
    if cache:
        X = _try_load(cache, 'train_X.npy')
        if X is not None:
            return X, _try_load(cache, 'train_y.npy'), _try_load(cache, 'train_snr.npy')

    cleans, y, _ = make_instances(n_per_class, seed=seed_train,
                                  n_points=n_points, fs=fs)
    rng = np.random.default_rng(seed_train + 1)          # 与实例生成错开的随机流
    snr = rng.uniform(*SNR_TRAIN_RANGE, size=len(y))
    X = np.stack([add_noise(c, s, rng, normalize) for c, s in zip(cleans, snr)])

    if cache:
        os.makedirs(cache, exist_ok=True)
        np.save(os.path.join(cache, 'train_X.npy'), X)
        np.save(os.path.join(cache, 'train_y.npy'), y)
        np.save(os.path.join(cache, 'train_snr.npy'), snr)
    return X, y, snr


def build_test_sets(n_per_class=500, seed_test=200, n_points=N_POINTS,
                    fs=FS, snr_grid=SNR_GRID, normalize=True, cache=None):
    """测试集：同一批实例在 SNR_GRID 各档各加一遍噪声。

    返回:
        {snr: (X, y)}，X 形状 (N, 1, n_points)。
        同一 snr 档内的信号实例相同、噪声不同 → 曲线只反映 SNR 的影响。
    """
    if cache:
        npz = os.path.join(cache, 'test_sets.npz')
        if os.path.exists(npz):
            d = np.load(npz)
            return {int(k[2:]): (d[k], d['y_' + k[2:]])
                    for k in d.files if k.startswith('X_')}

    cleans, y, _ = make_instances(n_per_class, seed=seed_test,
                                  n_points=n_points, fs=fs)
    sets = {}
    for i, snr in enumerate(snr_grid):
        rng = np.random.default_rng(seed_test + 10 + i)   # 各档噪声流不同
        X = np.stack([add_noise(c, snr, rng, normalize) for c in cleans])
        sets[snr] = (X, y.copy())

    if cache:
        os.makedirs(cache, exist_ok=True)
        save = {}
        for snr, (X, y) in sets.items():
            save[f'X_{snr}'] = X
            save[f'y_{snr}'] = y
        np.savez(os.path.join(cache, 'test_sets.npz'), **save)
    return sets


def _try_load(cache, name):
    p = os.path.join(cache, name)
    if os.path.exists(p):
        return np.load(p)
    return None


# ============================================================================
# 三、命令行演示
# ============================================================================
if __name__ == '__main__':
    X, y, snr = build_train_set(n_per_class=50)
    test_sets = build_test_sets(n_per_class=20)
    print(f'训练集 X={X.shape} y={y.shape} 类别分布={np.bincount(y)}')
    print(f'训练 SNR 范围: [{snr.min():.1f}, {snr.max():.1f}] dB')
    for s, (Xs, ys) in test_sets.items():
        print(f'测试集 SNR={s:4d}dB: X={Xs.shape} 类别分布={np.bincount(ys)}')
    # 可复现性检查
    X2, y2, _ = build_train_set(n_per_class=50)
    print('同参数重复生成一致:', np.array_equal(X, X2))
