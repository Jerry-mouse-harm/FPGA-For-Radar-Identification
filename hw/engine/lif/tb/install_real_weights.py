#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 src/export/export_int8.py 的真实导出权重装进本地 RTL / 测试台。

用法：
  cd hw/engine/lif
  python tb/install_real_weights.py [--src ../../../../results/export_int8]

做的事：
  1) 复制 conv1/conv2 的 ROM 与权重文本（导出格式与本目录完全一致）：
       <src>/conv1_wrom.v      -> rtl/conv1_wrom.v
       <src>/conv1_weights.txt -> tb/conv1_weights.txt
       <src>/conv2_wrom.v      -> rtl/conv2_wrom.v
       <src>/conv2_weights.txt -> tb/conv2_weights.txt
  2) 合并导出格式的 FC1（W r c / B r / T r）+ FC2（W c r / B c）为
     tb/fc1_weights.txt（W1 r c / B1 r / T1 r / W2 c r / B2 c），
     并按 rtl/fc1_wrom.v / rtl/readout_wrom.v 的既有布局生成真实 ROM。

注意：本脚本会覆盖 rtl/conv{1,2}_wrom.v、rtl/fc1_wrom.v、rtl/readout_wrom.v
和 tb/*_weights.txt。想回到占位权重，重跑 tb/gen_conv{1,2}_weights.py /
tb/gen_fc1_weights.py 即可。
"""

import argparse
import json
import os
import shutil

NR, NIN, NC = 32, 512, 5
BANKS = NR // 4
K1, C1 = 5, 8
CI2, CO2, K2 = 8, 16, 5

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)                       # hw/engine/lif


def load_tags(path, allowed):
    """读 'TAG idx... val' 文本，返回 {tag: {idx 元组: val}}。

    兼容 W c k val / W o i k val / W r c val / B r val / T r val 等。
    """
    out = {t: {} for t in allowed}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            p = line.split()
            if p[0] not in out or len(p) < 3:
                raise ValueError(f'{path}: 未知行 {line}')
            key = tuple(int(x) for x in p[1:-1])
            out[p[0]][key] = int(p[-1])
    return out


def check_int8(name, vals):
    bad = [v for v in vals if not -128 <= v <= 127]
    assert not bad, f'{name}: 有 {len(bad)} 个权重超出 int8'


def vlit16(v):
    return f"-16'sd{-v}" if v < 0 else f"16'sd{v}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=os.path.join(
        root, '..', '..', '..', 'results', 'export_int8'))
    args = ap.parse_args()
    src = os.path.abspath(args.src)
    print(f'源目录: {src}')

    # ---------------- Conv1 / Conv2：直接复制 ----------------
    for name in ('conv1_wrom.v', 'conv1_weights.txt',
                 'conv2_wrom.v', 'conv2_weights.txt'):
        shutil.copyfile(os.path.join(src, name),
                        os.path.join(root, 'rtl' if name.endswith('.v') else 'tb', name))
    c1 = load_tags(os.path.join(src, 'conv1_weights.txt'), 'WBT')
    assert len(c1['W']) == C1 * K1 and len(c1['B']) == C1 and len(c1['T']) == C1
    check_int8('conv1', c1['W'].values())
    c2 = load_tags(os.path.join(src, 'conv2_weights.txt'), 'WBT')
    assert len(c2['W']) == CO2 * CI2 * K2 and len(c2['B']) == CO2 and len(c2['T']) == CO2
    check_int8('conv2', c2['W'].values())

    # ---------------- FC1 (512->32) + FC2 (32->5) ----------------
    fc1 = load_tags(os.path.join(src, 'fc1_weights.txt'), 'WBT')
    fc2 = load_tags(os.path.join(src, 'fc2_weights.txt'), 'WBT')
    assert len(fc1['W']) == NR * NIN, f"FC1 权重数 {len(fc1['W'])}"
    assert len(fc1['B']) == NR and len(fc1['T']) == NR
    assert len(fc2['W']) == NC * NR, f"FC2 权重数 {len(fc2['W'])}"
    assert len(fc2['B']) == NC
    check_int8('fc1', fc1['W'].values())
    check_int8('fc2', fc2['W'].values())

    W1 = [[fc1['W'][(r, c)] for c in range(NIN)] for r in range(NR)]
    B1 = [fc1['B'][(r,)] for r in range(NR)]
    TH1 = [fc1['T'][(r,)] for r in range(NR)]
    W2 = [[fc2['W'][(c, r)] for r in range(NR)] for c in range(NC)]
    B2 = [fc2['B'][(c,)] for c in range(NC)]
    assert all(t >= 1 for t in TH1), 'FC1 阈值必须 >= 1'

    # ---------------- tb/fc1_weights.txt（合并格式）----------------
    with open(os.path.join(here, 'fc1_weights.txt'), 'w') as f:
        f.write('# 自动生成：install_real_weights.py（源 results/export_int8）\n')
        f.write('# W1 r c val / B1 r val / T1 r val / W2 c r val / B2 c val\n')
        for r in range(NR):
            for c in range(NIN):
                f.write(f'W1 {r} {c} {W1[r][c]}\n')
        for r in range(NR):
            f.write(f'B1 {r} {B1[r]}\n')
        for r in range(NR):
            f.write(f'T1 {r} {TH1[r]}\n')
        for c in range(NC):
            for r in range(NR):
                f.write(f'W2 {c} {r} {W2[c][r]}\n')
        for c in range(NC):
            f.write(f'B2 {c} {B2[c]}\n')

    # ---------------- rtl/fc1_wrom.v ----------------
    lines = [
        '// 自动生成：tb/install_real_weights.py —— 请勿手改',
        '// FC1 权重 ROM（真实低 SNR 精调部署权重，int8 定点）',
        f'// 布局：addr_w = c（0..{NIN-1}，c = o*32+j）；dout_w[8*r +: 8] = W1[r][c]',
        f'// {BANKS} 个银行 × {NIN} × 32 bit；同步读、1 拍延迟。',
        '// 偏置/阈值是每神经元常量，直接 assign，不占存储。',
        '',
        'module fc1_wrom (',
        '  input  wire               clk,',
        '  input  wire [8:0]         addr_w,',
        '  output wire [255:0]       dout_w,',
        '  output wire signed [511:0] dout_b,',
        '  output wire signed [511:0] dout_t',
        ');',
        '',
    ]
    for j in range(BANKS):
        lines.append(f'  reg [31:0] bank{j} [0:{NIN-1}];')
    lines.append('')
    lines.append('  initial begin')
    for j in range(BANKS):
        for c in range(NIN):
            word = 0
            for q in range(4):
                word |= (W1[j * 4 + q][c] & 0xFF) << (8 * q)
            lines.append(f'    bank{j}[{c}] = 32\'h{word:08x};')
    lines.append('  end')
    lines.append('')
    for j in range(BANKS):
        lines.append(f'  reg [31:0] q{j};')
    lines.append('  always @(posedge clk) begin')
    for j in range(BANKS):
        lines.append(f'    q{j} <= bank{j}[addr_w];')
    lines.append('  end')
    lines.append('')
    lines.append('  assign dout_w = {' +
                 ', '.join(f'q{j}' for j in range(BANKS - 1, -1, -1)) + '};')
    lines.append('')
    lines.append('  assign dout_b = {' +
                 ', '.join(vlit16(B1[r]) for r in range(NR - 1, -1, -1)) + '};')
    lines.append('  assign dout_t = {' +
                 ', '.join(vlit16(TH1[r]) for r in range(NR - 1, -1, -1)) + '};')
    lines.append('')
    lines.append('endmodule')
    lines.append('')
    with open(os.path.join(root, 'rtl', 'fc1_wrom.v'), 'w') as f:
        f.write('\n'.join(lines))

    # ---------------- rtl/readout_wrom.v ----------------
    lines = [
        '// 自动生成：tb/install_real_weights.py —— 请勿手改',
        '// 读出层权重 ROM（真实低 SNR 精调部署权重，int8 定点）',
        '// addr = r（0..31）；dout_w[8*c +: 8] = W2[c][r]；组合 case。',
        '',
        'module readout_wrom (',
        '  input  wire [4:0]       addr_r,',
        '  output reg  [39:0]      dout_w,',
        '  output wire signed [79:0] dout_b',
        ');',
        '',
        '  always @(*) begin',
        '    case (addr_r)',
    ]
    for r in range(NR):
        word = 0
        for c in range(NC):
            word |= (W2[c][r] & 0xFF) << (8 * c)
        lines.append(f"      5'd{r}: dout_w = 40'h{word:010x};")
    lines += [
        "      default: dout_w = 40'sd0;",
        '    endcase',
        '  end',
        '',
        '  assign dout_b = {' +
        ', '.join(vlit16(B2[c]) for c in range(NC - 1, -1, -1)) + '};',
        '',
        'endmodule',
        '',
    ]
    with open(os.path.join(root, 'rtl', 'readout_wrom.v'), 'w') as f:
        f.write('\n'.join(lines))

    # ---------------- 汇报 ----------------
    print('Conv1/Conv2 ROM + 权重文本已复制')
    print(f'FC1: {NR}×{NIN} -> rtl/fc1_wrom.v；阈值 = '
          f'{sorted(set(TH1))}；b ∈ [{min(B1)}, {max(B1)}]')
    print(f'FC2: {NC}×{NR} -> rtl/readout_wrom.v；B2 = {B2}')
    worst = NC * (max(abs(w) for c in W2 for w in c) * 16 * NR +
                  max(abs(b) for b in B2) * 16)
    print(f'logits 保守上界 |logit| <= {worst}（20 bit 有符号上限 524287）')
    assert worst < (1 << 19), 'logits 可能超出 20 位'
    try:
        with open(os.path.join(src, 'manifest.json')) as f:
            m = json.load(f)
        print('量化尺度 s_w:', {k: round(v['s_w'], 8) for k, v in m['layers'].items()})
        print('源 checkpoint:', m['source_checkpoint'],
              'sha256:', m['source_sha256'][:16] + '...')
    except (OSError, KeyError, json.JSONDecodeError):
        pass
    print('完成。下一步：make conv1 conv2 fc1 readout engine')


if __name__ == '__main__':
    main()
