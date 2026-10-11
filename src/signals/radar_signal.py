# -*- coding: utf-8 -*-
"""
radar_signal.py —— 雷达信号生成库（Day 1 预实验）
=====================================================
生成 5 类雷达信号：

    1. Pulse  常规脉冲  : 固定载频的矩形脉冲
    2. LFM    线性调频  : 脉冲内频率线性扫描（Chirp）
    3. BPSK   二相相移  : 按二元码 ±1 在 0°/180° 间跳相
    4. FSK    频移键控  : 若干离散频率跳变
    5. CW     连续波    : 持续正弦波

提供：
    - 每类信号的波形生成
    - 随机参数生成（带宽、载频、脉宽、码率等）
    - 加 AWGN 噪声（任意 SNR，-5~20 dB）
    - 批量数据集生成（供后续 PyTorch 训练）
    - 时域 / 时频（STFT）可视化

用法示例：
    import radar_signal as rs
    clean, noisy, params = rs.generate_signal('LFM', fs=10e6, n_points=1024, snr_db=10)
    rs.plot_signal(noisy, fs=10e6, title='LFM SNR=10dB')

作者：fpga_contest / 2026-08-31
"""

import numpy as np
import matplotlib.pyplot as plt
from scipy import signal as sp_signal
from matplotlib import font_manager

# 配置中文字体（否则图中中文会显示为方框）
for _f in ('WenQuanYi Micro Hei', 'SimHei', 'Noto Sans CJK SC', 'KaiTi'):
    try:
        font_manager.findfont(_f, fallback_to_default=False)
    except Exception:
        continue
    plt.rcParams['font.sans-serif'] = [_f, 'DejaVu Sans']
    plt.rcParams['axes.unicode_minus'] = False   # 负号正常显示
    break

# 5 类信号类型（顺序固定，作为类别索引：0=Pulse 1=LFM 2=BPSK 3=FSK 4=CW）
SIGNAL_TYPES = ['Pulse', 'LFM', 'BPSK', 'FSK', 'CW']

# 默认采样率（10 MHz）
DEFAULT_FS = 10e6

# 随机参数自适应：保证每码片/每段至少有这些采样点（短窗口时减少码片/段数）
MIN_CHIP_SAMPLES = 6     # BPSK 每个码片最少采样数
MIN_SEG_SAMPLES = 8      # FSK 每个频率段最少采样数


# ============================================================================
# 一、时间轴与基础工具
# ============================================================================
def time_vector(fs, n_points):
    """生成时间轴：t = [0, 1/fs, 2/fs, ..., (n_points-1)/fs]"""
    return np.arange(n_points) / fs


def _window(n_points, frac, frac_start=0.0):
    """返回某个脉冲段在信号中的 [起始, 结束) 索引。
    frac      : 脉冲时长占整个信号的比例 (0~1)
    frac_start: 脉冲起始位置占信号的比例 (0~1)
    """
    i0 = int(round(frac_start * n_points))
    i1 = min(i0 + int(round(frac * n_points)), n_points)
    return i0, i1


# ============================================================================
# 二、5 类信号生成（返回长度为 n_points 的实信号 float 数组）
# ============================================================================
def gen_pulse(fs, n_points, fc, tau=0.3, t0=0.2):
    """常规脉冲：在 [t0, t0+tau] 窗口内发射载频 fc 的正弦，其余为 0。
    参数:
        fc  : 载频 (Hz)
        tau : 脉宽（占整个信号的比例 0~1）
        t0  : 脉冲起始位置（比例 0~1）
    """
    t = time_vector(fs, n_points)
    i0, i1 = _window(n_points, tau, t0)
    sig = np.zeros(n_points)
    sig[i0:i1] = np.cos(2 * np.pi * fc * t[i0:i1])
    return sig


def gen_lfm(fs, n_points, fc, bandwidth, tau=0.5, t0=0.1, up=True):
    """线性调频（LFM / Chirp）：脉宽 tau 内瞬时频率以 fc 为中心，
    从 fc-B/2 线性扫到 fc+B/2（up=True 上扫，up=False 下扫）。
    信号: 瞬时频率 f(t') = fc + sign·k·(t'-T/2)，k = bandwidth/T，
         相位 φ(t') = 2π(fc·t' + sign·(½k·t'² - ½k·T·t'))，t' 为脉内时间。
    参数:
        fc       : 中心频率 (Hz)
        bandwidth: 带宽 B (Hz)
        tau      : 脉宽（比例）
        up       : True=上扫频，False=下扫频
    """
    t = time_vector(fs, n_points)
    i0, i1 = _window(n_points, tau, t0)
    t_pulse = t[i0:i1] - t[i0]                    # 脉冲内相对时间（秒）
    tau_sec = (i1 - i0) / fs
    k = bandwidth / tau_sec                       # 调频斜率 (Hz/s)
    sign = 1.0 if up else -1.0
    # 相位 = 对瞬时频率积分，使扫频范围围绕 fc 对称
    phase = 2 * np.pi * (fc * t_pulse
                         + sign * (0.5 * k * t_pulse ** 2
                                   - 0.5 * k * tau_sec * t_pulse))
    sig = np.zeros(n_points)
    sig[i0:i1] = np.cos(phase)
    return sig


def gen_bpsk(fs, n_points, fc, code, tau=0.6):
    """二相相移键控（BPSK）：脉冲内按 code(±1) 序列分片改变相位（0° / 180°）。
    每个码片时长 = tau / len(code)，相位 = π·(1-code)/2，等价于乘 ±1。
    参数:
        code: ±1 组成的二元序列（如 Barker 码或随机码）
        tau : 编码总时长（比例）
    """
    t = time_vector(fs, n_points)
    i0, i1 = _window(n_points, tau, 0.15)
    n_code = len(code)
    n_chip = max(1, int(round((i1 - i0) / n_code)))   # 每个码片采样点数
    sig = np.zeros(n_points)
    for i, c in enumerate(code):
        c0 = i0 + i * n_chip
        c1 = min(c0 + n_chip, i1, n_points)           # 不越出编码窗口
        if c0 >= c1:
            continue
        sig[c0:c1] = c * np.cos(2 * np.pi * fc * t[c0:c1])
    return sig


def gen_fsk(fs, n_points, fc, freqs, tau=0.7, rng=None):
    """频移键控（FSK）：tau 时长内按 freqs 序列依次发射各频率，每段等长。
    参数:
        freqs: 各段频率列表（Hz），段数 = len(freqs)
        tau  : 编码总时长（比例）
        rng  : 随机数生成器（决定每段初相），None 则新建
    """
    rng = np.random.default_rng() if rng is None else rng
    t = time_vector(fs, n_points)
    i0, i1 = _window(n_points, tau, 0.1)
    n_seg = len(freqs)
    n_part = max(1, int(round((i1 - i0) / n_seg)))
    sig = np.zeros(n_points)
    for i, f in enumerate(freqs):
        p0 = i0 + i * n_part
        p1 = min(p0 + n_part, i1, n_points)           # 不越出编码窗口
        if p0 >= p1:
            continue
        phase0 = 2 * np.pi * rng.uniform(0, 1)   # 每段随机初相（模拟真实频率跳变）
        sig[p0:p1] = np.cos(2 * np.pi * f * t[p0:p1] + phase0)
    return sig


def gen_cw(fs, n_points, fc):
    """连续波（CW）：整个信号时长内持续发射载频 fc。"""
    t = time_vector(fs, n_points)
    return np.cos(2 * np.pi * fc * t)


# ============================================================================
# 三、随机参数生成（对应"每类随机参数"需求）
# ============================================================================
def random_params(sig_type, fs=DEFAULT_FS, n_points=1024, rng=None):
    """为指定信号类型随机生成一组合理参数。
    载频范围相对 fs=10MHz 设计（< 奈奎斯特 5MHz）。
    """
    rng = np.random.default_rng() if rng is None else rng
    fc = rng.uniform(1.0, 3.5) * 1e6      # 载频 1~3.5 MHz（fs=10MHz 时留足奈奎斯特余量）

    if sig_type == 'Pulse':
        return dict(fc=fc,
                    tau=rng.uniform(0.1, 0.5),   # 脉宽 10%~50% 时长
                    t0=rng.uniform(0.1, 0.4))
    elif sig_type == 'LFM':
        b = rng.uniform(0.5, 2.0) * 1e6          # 带宽 0.5~2 MHz
        # fc 为中心频率；约束扫频范围 [fc-B/2, fc+B/2] 不为负、不超奈奎斯特
        fc_lo = max(b / 2 + 0.2e6, 1.0e6)
        fc_hi = max(fc_lo, fs / 2 - b / 2 - 0.2e6)
        fc = rng.uniform(fc_lo, fc_hi)
        return dict(fc=fc,
                    bandwidth=b,
                    tau=rng.uniform(0.3, 0.8),
                    up=bool(rng.integers(0, 2)))
    elif sig_type == 'BPSK':
        tau = rng.uniform(0.4, 0.8)
        # 码片数随窗口自适应：保证每码片至少 MIN_CHIP_SAMPLES 个采样
        n_max = max(1, int(tau * n_points) // MIN_CHIP_SAMPLES)
        n_hi = min(31, n_max)
        n_lo = min(7, n_hi)
        n_chip = int(rng.integers(n_lo, n_hi + 1))
        code = 2 * rng.integers(0, 2, size=n_chip) - 1   # ±1 随机码
        return dict(fc=fc,
                    code=code,
                    tau=tau)
    elif sig_type == 'FSK':
        tau = rng.uniform(0.5, 0.9)
        # 段数随窗口自适应：保证每段至少 MIN_SEG_SAMPLES 个采样
        n_hop_max = max(2, int(tau * n_points) // MIN_SEG_SAMPLES)
        n_hi = min(8, n_hop_max)
        n_lo = min(3, n_hi)
        n_hop = int(rng.integers(n_lo, n_hi + 1))
        step = rng.uniform(0.2, 0.5) * 1e6       # 频率间隔 0.2~0.5 MHz
        span = (n_hop - 1) * step                # 跳频总跨度
        fc_lo = 0.5e6                            # 最低跳频不贴近 0
        fc_hi = max(fc_lo, fs / 2 - span - 0.2e6)  # 最高跳频不超奈奎斯特
        fc = rng.uniform(fc_lo, fc_hi)           # fc 取最低跳频
        freqs = fc + np.arange(n_hop) * step
        return dict(fc=fc, freqs=freqs, tau=tau)
    elif sig_type == 'CW':
        return dict(fc=fc)
    else:
        raise ValueError(f'未知信号类型: {sig_type}，可选 {SIGNAL_TYPES}')


# ============================================================================
# 四、主入口：生成单样本（含加噪）
# ============================================================================
def _generate_clean(sig_type, fs, n_points, params, rng=None):
    """根据类型和参数生成无噪声信号"""
    if sig_type == 'Pulse':
        return gen_pulse(fs, n_points, params['fc'], params['tau'], params['t0'])
    elif sig_type == 'LFM':
        return gen_lfm(fs, n_points, params['fc'], params['bandwidth'],
                       params['tau'], params.get('t0', 0.1), params['up'])
    elif sig_type == 'BPSK':
        return gen_bpsk(fs, n_points, params['fc'], params['code'], params['tau'])
    elif sig_type == 'FSK':
        return gen_fsk(fs, n_points, params['fc'], params['freqs'],
                       params['tau'], rng)
    elif sig_type == 'CW':
        return gen_cw(fs, n_points, params['fc'])
    raise ValueError(f'未知信号类型: {sig_type}')


def add_awgn(signal, snr_db, rng=None):
    """加高斯白噪声（AWGN）。
    定义: SNR = 10·log10(P_signal / P_noise)，P_signal 为整段信号的平均功率
    （含静默区）。因此脉冲类信号在脉内实际信噪比高于标称值。
    rng: 随机数生成器（可复现），None 则新建。
    """
    rng = np.random.default_rng() if rng is None else rng
    sig_power = np.mean(signal ** 2)
    if sig_power == 0:
        return signal.copy()
    noise_power = sig_power / (10 ** (snr_db / 10.0))
    noise = np.sqrt(noise_power) * rng.standard_normal(len(signal))
    return signal + noise


def generate_signal(sig_type, fs=DEFAULT_FS, n_points=1024, snr_db=None,
                    seed=None, rng=None, **param_overrides):
    """生成单个样本。

    返回:
        clean : 无噪声信号 (n_points,)
        noisy : 加噪信号 (n_points,)，snr_db 为 None 时为 None
        params: 本样本的参数 dict（含随机生成的参数 + 手动覆盖项）

    seed 与 rng 二选一：传 rng 时优先（供 generate_dataset 复用同一随机流，
    保证整批数据可复现）。
    """
    if rng is None:
        rng = np.random.default_rng(seed)
    params = random_params(sig_type, fs, n_points, rng)
    params.update(param_overrides)            # 手动指定参数可覆盖随机值
    clean = _generate_clean(sig_type, fs, n_points, params, rng)
    if snr_db is None:
        return clean, None, params
    return clean, add_awgn(clean, snr_db, rng), params


def generate_dataset(fs=DEFAULT_FS, n_points=1024, n_per_class=100,
                     snr_db=10.0, seed=0):
    """批量生成均衡数据集（每类 n_per_class 个带噪样本）。

    返回:
        X: (5*n_per_class, n_points) float32 数组
        y: (5*n_per_class,) int 数组，0~4 对应 SIGNAL_TYPES
    """
    rng = np.random.default_rng(seed)
    X_list, y_list = [], []
    for cls, sig_type in enumerate(SIGNAL_TYPES):
        for _ in range(n_per_class):
            clean, noisy, _ = generate_signal(sig_type, fs, n_points, snr_db,
                                              rng=rng)
            X_list.append(noisy.astype(np.float32))
            y_list.append(cls)
    return np.array(X_list), np.array(y_list)


# ============================================================================
# 五、可视化：时域 + 时频图（STFT 频谱图）
# ============================================================================
def spectrogram(x, fs=DEFAULT_FS, nperseg=128, noverlap=96):
    """短时傅里叶变换，返回 (f, t, Sxx_dB)。
    Sxx 为功率谱密度，用 dB 表示便于观察动态范围。
    """
    f, t, Sxx = sp_signal.spectrogram(x, fs=fs, nperseg=nperseg, noverlap=noverlap)
    Sxx = np.clip(Sxx, 1e-12, None)          # 避免 log(0)
    return f, t, 10 * np.log10(Sxx)


def plot_signal(x, fs=DEFAULT_FS, title='', snr_db=None, save_path=None, show=True):
    """画一张图：上半 时域，下半 时频（STFT）。
    时域 y 轴用 dBm 归一化（相对峰值）。
    """
    t = time_vector(fs, len(x))
    fig, axes = plt.subplots(2, 1, figsize=(10, 6), sharex=False)

    # 时域
    axes[0].plot(t * 1e6, x, lw=0.8)
    axes[0].set_xlabel('时间 (μs)')
    axes[0].set_ylabel('幅度')
    axes[0].set_title(title if not snr_db else f'{title}  (SNR={snr_db}dB)')
    axes[0].grid(True, alpha=0.3)

    # 时频
    f, tfd, Sxx = spectrogram(x, fs)
    im = axes[1].pcolormesh(tfd * 1e6, f / 1e6, Sxx, shading='gouraud',
                            cmap='jet')
    axes[1].set_xlabel('时间 (μs)')
    axes[1].set_ylabel('频率 (MHz)')
    axes[1].set_title('时频图 (STFT)')
    fig.colorbar(im, ax=axes[1], label='dB')

    fig.tight_layout()
    if save_path:
        fig.savefig(save_path, dpi=150)
    if show:
        plt.show()
    else:
        plt.close(fig)
    return fig


def plot_5types(fs=DEFAULT_FS, n_points=1024, snr_db=10, out_dir='figures'):
    """生成 5 类信号的对比图（每类一张：时域+时频），保存到 out_dir。"""
    import os
    os.makedirs(out_dir, exist_ok=True)
    saved = []
    for sig_type in SIGNAL_TYPES:
        clean, noisy, params = generate_signal(sig_type, fs, n_points, snr_db)
        # 用带噪信号出图（贴近真实观测）
        path = os.path.join(out_dir, f'{sig_type}_snr{int(snr_db)}dB.png')
        plot_signal(noisy, fs, title=f'{sig_type}', snr_db=snr_db,
                    save_path=path, show=False)
        saved.append(path)
    return saved


# ============================================================================
# 六、命令行演示入口：python3 radar_signal.py
# ============================================================================
if __name__ == '__main__':
    print('=== 雷达信号生成库 演示 ===')
    print('信号类型:', SIGNAL_TYPES)
    fig_saved = plot_5types(fs=10e6, n_points=1024, snr_db=10, out_dir='figures')
    print('已生成图:', fig_saved)

    # 生成一个小数据集验证形状
    X, y = generate_dataset(n_per_class=20, snr_db=10, seed=0)
    print(f'数据集形状 X={X.shape}, y={y.shape}')
    print('y 类别分布:', np.bincount(y))
