# -*- coding: utf-8 -*-
"""
export_int8.py —— 部署模型（低 SNR 精调版）→ int8 定点权重 / ROM / hex
=====================================================================
输入：results/model_snn_distill.pt（= 精调后的部署权重）
输出：results/export_int8/
    conv1_wrom.v / conv2_wrom.v   RTL ROM（与 tb/gen_conv*_weights.py 布局逐项一致）
    conv1_weights.txt             Conv1 权重文本（判分台金标准同款格式）
    conv2_weights.txt             Conv2 权重文本
    fc1_weights.txt / fc2_weights.txt
    hex/*.hex                     int8 权重 / int16 偏置与阈值的二补码 hex
    manifest.json                 每层 s_w / 整数范围 / 阈值 / 位宽需求
    verify_int8.txt               定点整数模拟 vs 浮点模型的逐 SNR 对拍

定点规则（hw/engine/lif/README.md 契约 v0.1，逐层独立）：
    s_w   = max|W| / 127
    W_int = clamp(round(W / s_w), -128, 127)
    b_int = round(b / s_w)
    th_int = max(1, round(th / s_w))        th 取训练后的最终阈值
    膜电位 LSB = s_w，16 位有符号饱和

读取层（fc2）不经过 LIF：硬件按 T 步脉冲计数读出
    argmax_c ( Σ_r W4_int[c,r] · count_r + b4_int[c] · T )

用法：
    python src/export/export_int8.py                  # 只导出
    python src/export/export_int8.py --skip-verify    # 跳过定点精度对拍
    python src/export/export_int8.py --install        # 覆盖 hw/engine/lif 的 ROM/权重文本
"""
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

PROJ = Path(__file__).resolve().parent.parent.parent
for _d in ('data', 'models'):
    sys.path.insert(0, str(PROJ / 'src' / _d))
import dataset                                   # noqa: E402
import snn_conv as S                             # noqa: E402

RESULTS = PROJ / 'results'
DEFAULT_CKPT = RESULTS / 'model_snn_distill.pt'
DEFAULT_OUT = RESULTS / 'export_int8'

T = 16
INV_SCALE = 8.0          # 训练端 inv_scale
DIN_SCALE = 16           # 硬件定点：x = din / 16
X_CLAMP = 4.0            # din ∈ [-64, 64]
VMAX, VMIN = 32767, -32768

LAYER_ORDER = ('conv1', 'conv2', 'fc1', 'fc2')
LIF_OF = {'conv1': 'lif1', 'conv2': 'lif2', 'fc1': 'lif3'}   # fc2 是读出层


# ============================================================================
# 一、量化
# ============================================================================
def signed_bits(v):
    """表示有符号整数 v 所需位宽（含符号位）。"""
    v = int(v)
    return (v if v >= 0 else ~v).bit_length() + 1


def quant_layer(W, b, th=None):
    """按契约 v0.1 把一层浮点权重/偏置/阈值量化成整数。"""
    W = np.asarray(W, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    amax = float(np.abs(W).max())
    s_w = amax / 127.0 if amax > 0 else 1.0
    W_int = np.clip(np.round(W / s_w), -128, 127).astype(np.int64)
    b_int = np.round(b / s_w).astype(np.int64)
    q = {'s_w': s_w, 'W': W_int, 'b': b_int,
         'th_float': None, 'th_int': None}
    if th is not None:
        q['th_float'] = float(th)
        q['th_int'] = max(1, int(np.round(float(th) / s_w)))
    return q


def quantize_model(ck):
    """从 checkpoint 取出各层权重与训练后的最终阈值。"""
    sd = ck['state_dict']

    def th_of(lif):
        return float(F.softplus(sd[f'{lif}.v_threshold_raw']) + 1e-3)

    q = {}
    q['conv1'] = quant_layer(sd['conv1.weight'].numpy().reshape(8, 5),
                             sd['conv1.bias'].numpy(), th_of('lif1'))
    q['conv2'] = quant_layer(sd['conv2.weight'].numpy(),
                             sd['conv2.bias'].numpy(), th_of('lif2'))
    q['fc1'] = quant_layer(sd['fc1.weight'].numpy(),
                           sd['fc1.bias'].numpy(), th_of('lif3'))
    q['fc2'] = quant_layer(sd['fc2.weight'].numpy(),
                           sd['fc2.bias'].numpy())          # 读出层无 LIF
    return q


# ============================================================================
# 二、写 RTL ROM（布局与 tb/gen_conv*_weights.py 完全一致）
# ============================================================================
def vlit(v):
    return f"-16'sd{-v}" if v < 0 else f"16'sd{v}"


def write_conv1_rom(path, q):
    C, K = 8, 5
    W, B = q['W'], q['b']
    TH = np.full(C, q['th_int'], dtype=np.int64)     # LIF 阈值是标量，各通道相同
    lines = [
        '// 自动生成：src/export/export_int8.py —— 请勿手改',
        '// Conv1 权重 ROM（真实低 SNR 精调部署权重，int8 定点）',
        f'// s_w = {q["s_w"]:.10f}；布局：0..39 = W[c][k]，40..47 = B[c]，48..55 = TH[c]',
        '// 三端口都是组合读（case 实现，不依赖 $readmemh / BSRAM 原语）',
        '',
        'module conv1_wrom (',
        '  input  wire [5:0]        addr_w,',
        '  input  wire [5:0]        addr_b,',
        '  input  wire [5:0]        addr_t,',
        '  output reg  signed [15:0] dout_w,',
        '  output reg  signed [15:0] dout_b,',
        '  output reg  signed [15:0] dout_t',
        ');',
        '',
        '  always @(*) begin',
        '    case (addr_w)',
    ]
    for c in range(C):
        for k in range(K):
            a = c * K + k
            lines.append(f"      6'd{a}: dout_w = {vlit(int(W[c, k]))};  // W[{c}][{k}]")
    lines += ['      default: dout_w = 16\'sd0;', '    endcase', '', '    case (addr_b)']
    for c in range(C):
        lines.append(f"      6'd{C * K + c}: dout_b = {vlit(int(B[c]))};  // B[{c}]")
    lines += ['      default: dout_b = 16\'sd0;', '    endcase', '', '    case (addr_t)']
    for c in range(C):
        lines.append(f"      6'd{C * K + C + c}: dout_t = {vlit(int(TH[c]))};  // TH[{c}]")
    lines += ['      default: dout_t = 16\'sd0;', '    endcase', '  end', '', 'endmodule', '']
    path.write_text('\n'.join(lines), encoding='utf-8')


def write_conv2_rom(path, q):
    CI, CO, K = 8, 16, 5
    W, B = q['W'], q['b']
    TH = np.full(CO, q['th_int'], dtype=np.int64)    # LIF 阈值是标量，各通道相同
    lines = [
        '// 自动生成：src/export/export_int8.py —— 请勿手改',
        '// Conv2 权重 ROM（真实低 SNR 精调部署权重，int8 定点）',
        f'// s_w = {q["s_w"]:.10f}；布局：addr_w = (o*8 + i)*5 + k，共 640 项；'
        'addr_b / addr_t = o（各 16 项）',
        '// 权重用同步 ROM；偏置/阈值只有 16 项，用组合 case。',
        '',
        'module conv2_wrom (',
        '  input  wire              clk,',
        '  input  wire [9:0]        addr_w,',
        '  input  wire [3:0]        addr_b,',
        '  input  wire [3:0]        addr_t,',
        '  output reg  signed [15:0] dout_w,',
        '  output reg  signed [15:0] dout_b,',
        '  output reg  signed [15:0] dout_t',
        ');',
        '',
        '  reg signed [15:0] wmem [0:639];',
        '',
        '  initial begin',
    ]
    for o in range(CO):
        for i in range(CI):
            for k in range(K):
                a = (o * CI + i) * K + k
                lines.append(f"    wmem[{a}] = {vlit(int(W[o, i, k]))};  // W[{o}][{i}][{k}]")
    lines += [
        '  end',
        '',
        '  always @(posedge clk)',
        '    dout_w <= wmem[addr_w];',
        '',
        '  always @(*) begin',
        '    case (addr_b)',
    ]
    for o in range(CO):
        lines.append(f"      4'd{o}: dout_b = {vlit(int(B[o]))};  // B[{o}]")
    lines += ['      default: dout_b = 16\'sd0;', '    endcase', '', '    case (addr_t)']
    for o in range(CO):
        lines.append(f"      4'd{o}: dout_t = {vlit(int(TH[o]))};  // TH[{o}]")
    lines += ['      default: dout_t = 16\'sd0;', '    endcase', '  end', '', 'endmodule', '']
    path.write_text('\n'.join(lines), encoding='utf-8')


# ============================================================================
# 三、写文本 / hex
# ============================================================================
def write_conv_texts(out_dir, q):
    q1, q2 = q['conv1'], q['conv2']
    lines = ['# 自动生成：src/export/export_int8.py —— 请勿手改',
             f'# Conv1 真实部署权重（int8，s_w={q1["s_w"]:.10f}）',
             '# W c k val / B c val / T c val']
    for c in range(8):
        for k in range(5):
            lines.append(f'W {c} {k} {int(q1["W"][c, k])}')
    for c in range(8):
        lines.append(f'B {c} {int(q1["b"][c])}')
    for c in range(8):
        lines.append(f'T {c} {int(q1["th_int"])}')
    (out_dir / 'conv1_weights.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')

    lines = ['# 自动生成：src/export/export_int8.py —— 请勿手改',
             f'# Conv2 真实部署权重（int8，s_w={q2["s_w"]:.10f}）',
             '# W o i k val / B o val / T o val']
    for o in range(16):
        for i in range(8):
            for k in range(5):
                lines.append(f'W {o} {i} {k} {int(q2["W"][o, i, k])}')
    for o in range(16):
        lines.append(f'B {o} {int(q2["b"][o])}')
    for o in range(16):
        lines.append(f'T {o} {int(q2["th_int"])}')
    (out_dir / 'conv2_weights.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')

    q3, q4 = q['fc1'], q['fc2']
    lines = ['# 自动生成：src/export/export_int8.py —— 请勿手改',
             f'# fc1 = Linear(512->32) + LIF3（int8，s_w={q3["s_w"]:.10f}）',
             '# 输入 = OR 池化后的 16x32 脉冲按 C 序展平（与 PyTorch flatten(1) 一致）',
             '# W r c val (32x512) / B r val / T r val（阈值）']
    for r in range(32):
        for c in range(512):
            lines.append(f'W {r} {c} {int(q3["W"][r, c])}')
    for r in range(32):
        lines.append(f'B {r} {int(q3["b"][r])}')
    for r in range(32):
        lines.append(f'T {r} {int(q3["th_int"])}')
    (out_dir / 'fc1_weights.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')

    lines = ['# 自动生成：src/export/export_int8.py —— 请勿手改',
             f'# fc2 = 读出层 Linear(32->5)（int8，s_w={q4["s_w"]:.10f}）',
             '# 输入 = LIF3 在 T=16 步内的脉冲计数 count_r (0..16)',
             '# logits_c = Σ_r W[c,r]*count_r + B[c]*T（除以 T 是全局缩放，不改 argmax）',
             '# W c r val / B c val']
    for c in range(5):
        for r in range(32):
            lines.append(f'W {c} {r} {int(q4["W"][c, r])}')
    for c in range(5):
        lines.append(f'B {c} {int(q4["b"][c])}')
    (out_dir / 'fc2_weights.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def write_hex(path, arr, width):
    """二补码 hex，一行一个数。width=8（int8）或 16（int16）。"""
    vals = np.asarray(arr).ravel()
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    if vals.size and (vals.min() < lo or vals.max() > hi):
        raise ValueError(f'{path.name}: 数值超出 int{width} 范围 '
                         f'[{int(vals.min())}, {int(vals.max())}]')
    mask = (1 << width) - 1
    digits = width // 4
    path.write_text(''.join(f'{(int(v) & mask):0{digits}x}\n' for v in vals),
                    encoding='utf-8')


def write_hex_files(out_dir, q):
    hx = out_dir / 'hex'
    hx.mkdir(exist_ok=True)
    for name in LAYER_ORDER:
        write_hex(hx / f'{name}_w.hex', q[name]['W'], 8)
        write_hex(hx / f'{name}_b.hex', q[name]['b'], 16)
        if q[name]['th_int'] is not None:
            # 阈值在 ROM 里按输出通道逐项存（LIF 实际是标量，值全相同）
            rows = q[name]['W'].shape[0]
            write_hex(hx / f'{name}_th.hex',
                      np.full(rows, q[name]['th_int'], dtype=np.int64), 16)


# ============================================================================
# 四、定点整数模拟（与 RTL 同一套算术）
# ============================================================================
def hw_input_spikes(X, T):
    """训练集样本 → 硬件编码前端脉冲 (T,B,128)。

    与 M6 sample_to_n 完全一致：din = round(clip(x,-4,4)*16)，
    n = clamp(((din+4) >>> 3) + 8, 0, 16)，再走 ΣΔ 累加器。
    """
    din = np.round(np.clip(X[:, 0, :], -X_CLAMP, X_CLAMP) * DIN_SCALE).astype(np.int64)
    n = np.clip(((din + 4) >> 3) + T // 2, 0, T)
    acc = np.zeros_like(n)
    out = np.empty((T,) + n.shape, dtype=np.int64)
    for t in range(T):
        acc += n
        s = acc >= T
        acc -= T * s
        out[t] = s
    return out


def _windows(x, pad, k):
    """x:(B,C,L) → (B,C,L,k) 滑窗，长度维两端补零。"""
    xp = np.pad(x.astype(np.float64), ((0, 0), (0, 0), (pad, pad)))
    return np.lib.stride_tricks.sliding_window_view(xp, k, axis=2)


def _conv_current(win, Wq):
    """win:(B,C,L,K), Wq:(O,C,K) → (B,O,L)，整数结果（float64 精确承载）。"""
    B, C, L, K = win.shape
    O = Wq.shape[0]
    # (B,C,L,K) → (B,L,C,K)：让每个位置的 C*K 个抽头连续，才能与 (O,C*K) 做矩阵乘
    a = win.transpose(0, 2, 1, 3).reshape(B * L, C * K)
    b = np.asarray(Wq, dtype=np.float64).reshape(O, C * K).T
    return (a @ b).reshape(B, L, O).transpose(0, 2, 1)


def _lif_step(v, x, th, sat_counter):
    """一步 LIF：饱和加 → 判发 → 软复位。返回 (v, spike)。"""
    vpre = v + np.round(x).astype(np.int64)
    sat_counter[0] += int(np.count_nonzero((vpre < VMIN) | (vpre > VMAX)))
    v = np.clip(vpre, VMIN, VMAX)
    s = v >= th
    v = v - th * s
    return v, s


def int_forward(spikes, q):
    """整数域整网前向。spikes:(T,B,128) → logits_int (B,5) 与统计量。"""
    Tn, B, _ = spikes.shape
    q1, q2, q3, q4 = q['conv1'], q['conv2'], q['fc1'], q['fc2']

    v1 = np.zeros((B, 8, 128), dtype=np.int64)
    v2 = np.zeros((B, 16, 64), dtype=np.int64)
    v3 = np.zeros((B, 32), dtype=np.int64)
    count3 = np.zeros((B, 32), dtype=np.int64)
    sat = {k: [0] for k in ('conv1', 'conv2', 'fc1')}
    xmax = {k: 0 for k in ('conv1', 'conv2', 'fc1')}

    for t in range(Tn):
        # ---- Conv1 ----
        win1 = _windows(spikes[t].astype(np.float64)[:, None, :], 2, 5)
        x1 = np.rint(_conv_current(win1, q1['W'])) + q1['b'][None, :, None]
        xmax['conv1'] = max(xmax['conv1'], int(np.abs(x1).max()))
        v1, s1 = _lif_step(v1, x1, q1['th_int'], sat['conv1'])
        p1 = (s1[:, :, 0::2] | s1[:, :, 1::2]).astype(np.int64)     # OR 池化

        # ---- Conv2 ----
        win2 = _windows(p1, 2, 5)
        x2 = np.rint(_conv_current(win2, q2['W'])) + q2['b'][None, :, None]
        xmax['conv2'] = max(xmax['conv2'], int(np.abs(x2).max()))
        v2, s2 = _lif_step(v2, x2, q2['th_int'], sat['conv2'])
        p2 = (s2[:, :, 0::2] | s2[:, :, 1::2]).astype(np.int64)
        flat2 = p2.reshape(B, -1)                                  # (B,512)

        # ---- FC1 ----
        x3 = np.rint(flat2.astype(np.float64) @ q3['W'].T.astype(np.float64)) \
            + q3['b'][None, :]
        xmax['fc1'] = max(xmax['fc1'], int(np.abs(x3).max()))
        v3, s3 = _lif_step(v3, x3, q3['th_int'], sat['fc1'])
        count3 += s3

    # ---- 读出层：脉冲计数 × int8 权重 ----
    logits = count3.astype(np.float64) @ q4['W'].T.astype(np.float64) \
        + q4['b'][None, :] * Tn
    pred = logits.argmax(1)
    stats = {'x_int_absmax': xmax,
             'saturations': {k: v[0] for k, v in sat.items()}}
    return pred, stats


# ============================================================================
# 五、浮点参考（用同一组量化参数的实数模型，隔离"定点算术"的影响）
# ============================================================================
@torch.no_grad()
def eval_dequant_float(ck, q, test_sets, batch=256):
    """把 int8 权重/阈值反量化回浮点，按训练编码评估。"""
    snn = S.ConvSNN(T=ck['T'], leak_shift=ck['leak_shift'],
                    hard_reset=ck['hard_reset'], use_qat=False,
                    w_bits=8, v_bits=16, thr_bits=8)
    snn.load_state_dict(ck['state_dict'])
    snn.use_qat = False
    for name in LAYER_ORDER:
        layer = getattr(snn, name)
        w = torch.from_numpy(q[name]['W']).float().reshape(layer.weight.shape)
        layer.weight.data.copy_(w * q[name]['s_w'])
        layer.bias.data.copy_(torch.from_numpy(
            q[name]['b']).float() * q[name]['s_w'])
    for layer, lif_name in LIF_OF.items():
        lif = getattr(snn, lif_name)
        lif.use_qat = False
        lif.v_threshold = float(q[layer]['th_int']) * q[layer]['s_w']
    snn.eval()

    accs, preds_all = {}, {}
    for snr in sorted(test_sets):
        X, y = test_sets[snr]
        preds = []
        for i in range(0, len(X), batch):
            xT = S.encode_input(torch.from_numpy(X[i:i + batch]), ck['T'],
                                ck['mode'], INV_SCALE)
            preds.append(snn(xT).argmax(1).numpy())
        pred = np.concatenate(preds)
        accum = float((pred == y).mean())
        accs[snr] = accum
        preds_all[snr] = pred
    return accs, preds_all


# ============================================================================
# 六、主流程
# ============================================================================
def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description='导出部署模型为 int8 定点权重')
    ap.add_argument('--ckpt', default=str(DEFAULT_CKPT))
    ap.add_argument('--out', default=str(DEFAULT_OUT))
    ap.add_argument('--skip-verify', action='store_true')
    ap.add_argument('--install', action='store_true',
                    help='覆盖 hw/engine/lif/rtl 的 conv*_wrom.v 与 tb 的权重文本')
    args = ap.parse_args()

    ckpt = Path(args.ckpt)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    ck = torch.load(str(ckpt), map_location='cpu', weights_only=False)
    q = quantize_model(ck)

    print('=' * 72)
    print(f'导出 {ckpt.name} → {out_dir}')
    print('=' * 72)
    for name in LAYER_ORDER:
        e = q[name]
        wmin, wmax = int(e['W'].min()), int(e['W'].max())
        bmin, bmax = int(e['b'].min()), int(e['b'].max())
        th = f"{e['th_int']} (浮点 {e['th_float']:.6f})" if e['th_int'] is not None else '—（读出层）'
        print(f'  {name:5s} shape={str(e["W"].shape):>12s}  s_w={e["s_w"]:.8f}  '
              f'W_int=[{wmin:+4d},{wmax:+4d}]  b_int=[{bmin:+5d},{bmax:+5d}]  th_int={th}')

    # ---- 文件 ----
    write_conv1_rom(out_dir / 'conv1_wrom.v', q['conv1'])
    write_conv2_rom(out_dir / 'conv2_wrom.v', q['conv2'])
    write_conv_texts(out_dir, q)
    write_hex_files(out_dir, q)

    # ---- 位宽需求（解析上界：输入全 1 / 全 0 的极限情形） ----
    analytic = {}
    for name in ('conv1', 'conv2', 'fc1'):
        b = q[name]['b']
        per_out = q[name]['W'].reshape(len(b), -1)
        hi = int((per_out.clip(min=0).sum(1) + b).max())
        lo = int((per_out.clip(max=0).sum(1) + b).min())
        analytic[name] = {'x_int_min': lo, 'x_int_max': hi,
                          'signed_bits': max(signed_bits(lo), signed_bits(hi))}

    # ---- 定点精度对拍 ----
    verify = None
    if not args.skip_verify:
        print('\n定点对拍：加载测试集 ...', flush=True)
        test_sets = dataset.build_test_sets(
            500, cache=str(RESULTS / 'data'))
        ck_accs = {int(s): float(a) for s, a in
                   zip(ck['snr_grid'], ck['accs'])} if 'accs' in ck else {}

        print('  评估去量化浮点参考 ...', flush=True)
        deq_accs, deq_preds = eval_dequant_float(ck, q, test_sets)

        print('  整数域模拟（硬件编码 + 饱和 + 软复位）...', flush=True)
        int_accs, int_preds, stats = {}, {}, {}
        for snr in sorted(test_sets):
            X, y = test_sets[snr]
            spikes = hw_input_spikes(X, T)
            pred, st = int_forward(spikes, q)
            int_accs[snr] = float((pred == y).mean())
            int_preds[snr] = pred
            stats[snr] = st

        print(f'\n{"SNR":>5} {"ckpt浮点":>9} {"去量化浮点":>10} {"int8定点":>9} '
              f'{"定点-浮点":>9} {"预测一致":>8}  饱和(c1/c2/fc1)')
        lines = ['# int8 导出定点对拍（硬件编码 din/16 + ΣΔ + 饱和 16 位）',
                 '# ckpt浮点 = checkpoint 记录的原始评估；去量化浮点 = W_int*s_w 的实数模型',
                 '# int8定点 = 整数算术；预测一致 = 两模型 argmax 相同比例',
                 'SNR,ckpt_fp,dequant_fp,int8_hw,delta_pp,agree,sat_conv1,sat_conv2,sat_fc1']
        for snr in sorted(test_sets):
            agree = float((deq_preds[snr] == int_preds[snr]).mean())
            s = stats[snr]['saturations']
            print(f'{snr:5d} {ck_accs.get(snr, float("nan")) * 100:8.2f}% '
                  f'{deq_accs[snr] * 100:9.2f}% {int_accs[snr] * 100:8.2f}% '
                  f'{(int_accs[snr] - deq_accs[snr]) * 100:+8.2f}pp '
                  f'{agree * 100:7.2f}%  {s["conv1"]}/{s["conv2"]}/{s["fc1"]}')
            lines.append(f'{snr},{ck_accs.get(snr, float("nan")):.4f},'
                         f'{deq_accs[snr]:.4f},{int_accs[snr]:.4f},'
                         f'{(int_accs[snr] - deq_accs[snr]) * 100:+.2f},'
                         f'{agree:.4f},{s["conv1"]},{s["conv2"]},{s["fc1"]}')
        (out_dir / 'verify_int8.txt').write_text('\n'.join(lines) + '\n',
                                                 encoding='utf-8')
        verify = {'ckpt_fp': ck_accs, 'dequant_fp': deq_accs,
                  'int8_hw': int_accs,
                  'int8_minus_dequant_pp':
                      {s: (int_accs[s] - deq_accs[s]) * 100 for s in int_accs},
                  'int_stats': stats}

    # ---- manifest ----
    manifest = {
        'source_checkpoint': str(ckpt.relative_to(PROJ)),
        'source_sha256': sha256(ckpt),
        'finetune': ck.get('finetune'),
        'T': ck['T'], 'mode': ck['mode'],
        'leak_shift': ck['leak_shift'], 'hard_reset': ck['hard_reset'],
        'fixed_point_contract': 'hw/engine/lif/README.md v0.1',
        'input_encoding': {
            'inv_scale': INV_SCALE, 'din_scale': DIN_SCALE,
            'x_clamp': X_CLAMP,
            'n_rule': 'clamp(((din+4) >>> 3) + T/2, 0, T), T=16',
        },
        'layers': {},
        'readout': {
            'formula': 'argmax_c ( Σ_r W_int[c,r]*count_r + b_int[c]*T )',
            'count_bits': 5,
        },
        'x_int_analytic': analytic,
        'verify': verify,
    }
    for name in LAYER_ORDER:
        e = q[name]
        manifest['layers'][name] = {
            'shape': list(e['W'].shape),
            's_w': e['s_w'],
            'w_int_min': int(e['W'].min()), 'w_int_max': int(e['W'].max()),
            'b_int_min': int(e['b'].min()), 'b_int_max': int(e['b'].max()),
            'th_float': e['th_float'], 'th_int': e['th_int'],
        }
    (out_dir / 'manifest.json').write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding='utf-8')

    # ---- 可选安装到 RTL / 判分台 ----
    if args.install:
        lif = PROJ / 'hw' / 'engine' / 'lif'
        shutil.copy2(out_dir / 'conv1_wrom.v', lif / 'rtl' / 'conv1_wrom.v')
        shutil.copy2(out_dir / 'conv2_wrom.v', lif / 'rtl' / 'conv2_wrom.v')
        shutil.copy2(out_dir / 'conv1_weights.txt', lif / 'tb' / 'conv1_weights.txt')
        shutil.copy2(out_dir / 'conv2_weights.txt', lif / 'tb' / 'conv2_weights.txt')
        print(f'\n已覆盖 {lif}/rtl/conv{{1,2}}_wrom.v 与 tb/conv{{1,2}}_weights.txt')
        print('  注意：tb/gen_conv*_vectors.py 里有占位权重的自检锚点，'
              '换真实权重后需先改锚点再重新生成向量，')
        print('        否则 `make conv1/conv2` 的金标准还是旧占位权重。')

    print(f'\n导出完成：{out_dir}')
    print(f'  conv1_wrom.v / conv2_wrom.v / conv*_weights.txt / fc*_weights.txt')
    print(f'  hex/*.hex（int8 权重、int16 偏置/阈值） / manifest.json')
    if verify is not None:
        print(f'  verify_int8.txt（定点 vs 浮点逐 SNR 对拍）')


if __name__ == '__main__':
    main()
