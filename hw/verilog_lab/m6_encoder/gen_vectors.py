#!/usr/bin/env python3
"""生成 M6 判分台的金标准向量（给 tb_sample_to_n / tb_spike_encoder / tb_m6_chain 读）。

金标准不是手抄公式，而是**直接调用项目自己的编码器**
`src/models/snn_conv.py: encode_input(..., mode='spread')` —— 这样 M6 的题面天然和
训练/部署同域（LOG.md 的铁律：编码域不一致掉 24~40pp；同域下 spread 只比 direct 掉 0.7pp）。

用法（需要 torch，本机在 base 环境）：
    cd /home/jierui/fpga_contest
    /home/jierui/miniconda3/bin/python hw/verilog_lab/m6_encoder/gen_vectors.py

产出（与本脚本同目录）：
    n_pattern.hex   第 n 行 = 脉冲数 n 时那 16 步的发放图案（bit t = 第 t 步的 spike）
    sample_n.hex    每行 4 位十六进制 = {din[7:0], n[7:0]}，din 为有符号 8 位

定点约定（就是题面里写死的那条）：
    x = din/16                      （1 LSB = 1/16）
    x01 = clamp(x/8 + 0.5, 0, 1)    （项目 inv_scale=8）
    n   = round(x01 * T)   → 代入得  n = round(din/8 + T/2)，T=16 即 round(din/8 + 8)
"""
import os
import sys

T     = 16
INV   = 8.0
SCALE = 16.0            # 硬件定点：x = din / SCALE

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.abspath(os.path.join(HERE, '..', '..', '..', 'src', 'models'))
sys.path.insert(0, SRC)

import torch                     # noqa: E402
import snn_conv as S             # noqa: E402

# 测试样本：覆盖 钳位两端 / 零 / 正负尾数（尾数 5,6,7 才能区分"四舍五入"和"直接截断"）
# 刻意避开 din ≡ 4 (mod 8) —— 那些点软件用银行家舍入、硬件用加半 LSB，n 会差 1（见 README）
DINS = [-128, -127, -64, -63, -56, -33, -16, -9, -8, -7, -1,
        0, 1, 2, 5, 7, 8, 13, 15, 16, 21, 23, 31, 32, 63, 64, 127]


def sw_n(din):
    """软件规则：x01 = clamp(x/8+0.5,0,1) 之后 round（Python/torch 同为银行家舍入）。"""
    x01 = min(max(din / SCALE / INV + 0.5, 0.0), 1.0)
    return int(round(x01 * T))


def hw_n(din):
    """硬件规则：加半个 LSB 再算术右移，最后钳位到 [0,T]。"""
    return min(max(((din + 4) >> 3) + T // 2, 0), T)


def acc_pattern(n):
    """ΣΔ 累加器行为模型（就是题面第 3 条那句话）。"""
    acc, pat = 0, 0
    for t in range(T):
        acc += n
        if acc >= T:
            pat |= 1 << t
            acc -= T
    return pat


def closed_pattern(n):
    """闭式等价：s[t] = floor((t+1)n/T) - floor(t·n/T)（src 里向量化用的那个）。"""
    pat = 0
    for t in range(T):
        if (t + 1) * n // T - t * n // T:
            pat |= 1 << t
    return pat


def main():
    # ---- 图案表 n=0..T：让软件编码器吐 x01 = n/T（inv_scale=1、x 抵消掉 +0.5）----
    xs_n = torch.tensor([n / T - 0.5 for n in range(T + 1)], dtype=torch.float32).view(-1, 1, 1)
    spk_n = S.encode_input(xs_n, T, mode='spread', inv_scale=1.0)     # (T, T+1, 1, 1)

    pat_sw = [sum(int(spk_n[t, n, 0, 0].item()) << t for t in range(T))
              for n in range(T + 1)]
    for n in range(T + 1):
        assert pat_sw[n] == acc_pattern(n) == closed_pattern(n), \
            f'n={n}: 软件 {pat_sw[n]:04x} / 累加器 {acc_pattern(n):04x} / 闭式 {closed_pattern(n):04x} 不一致'

    with open(os.path.join(HERE, 'n_pattern.hex'), 'w') as f:
        for n in range(T + 1):
            f.write(f'{pat_sw[n]:04x}\n')

    # ---- 样本 → n：走项目真正的编码路径（float32 下 din/16、din/128 都是二进制精确的）----
    xs = torch.tensor([d / SCALE for d in DINS], dtype=torch.float32).view(-1, 1, 1)
    spk = S.encode_input(xs, T, mode='spread', inv_scale=INV)         # (T, B, 1, 1)

    rows = []
    print(f'  {"din":>5}  {"x":>9}  {"n":>2}  pattern')
    for b, din in enumerate(DINS):
        n_ref = sw_n(din)
        p     = sum(int(spk[t, b, 0, 0].item()) << t for t in range(T))
        assert p == acc_pattern(n_ref) == closed_pattern(n_ref), f'din={din}: 软件编码与模型不符'
        assert hw_n(din) == n_ref, f'din={din}: 硬件整数规则 {hw_n(din)} != 软件 {n_ref}'
        rows.append((din, n_ref))
        print(f'  {din:5d}  {din/SCALE:9.4f}  {n_ref:2d}  {p:016b}')

    with open(os.path.join(HERE, 'sample_n.hex'), 'w') as f:
        for din, n in rows:
            f.write(f'{din & 0xFF:02x}{n:02x}\n')

    # ---- 顺带报一下"刻意避开"的那些点：硬件与软件会差 1 个脉冲 ----
    ties = [(din, hw_n(din), sw_n(din))
            for din in range(-80, 81) if din % 8 in (4, -4) and hw_n(din) != sw_n(din)]

    print(f'\n  n_pattern.hex : {T + 1} 行（n = 0..{T}）')
    print(f'  sample_n.hex  : {len(rows)} 行')
    print(f'  舍入 tie 点（已避开）{len(ties)} 个，例: {ties[:3]}')
    print('  OK: 软件编码 == 累加器模型 == 闭式 == 硬件整数规则')


if __name__ == '__main__':
    main()
