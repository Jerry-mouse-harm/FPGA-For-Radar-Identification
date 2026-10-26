#!/usr/bin/env python3
"""把引擎判分台的 9 帧样本转成上板 ROM（engine_sample_rom.v）。

输入：hw/engine/lif/tb/engine_smp.hex —— 1152 行 = 9 帧 × 128 样本，
      每行 2 位十六进制（int8 补码），顺序与 tb_engine_top 一致。
输出：engine_sample_rom.v —— 同步读 ROM（1 拍延迟，正好对上 engine_top 的
      smp_addr/smp_data 契约）。内容直接写进 initial 块，不依赖 $readmemh，
      避免综合时的工作目录/路径问题。

用法（在 hw/board 下）：
    python3 engine_demo/gen_engine_sample_rom.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, '..', '..', 'engine', 'lif', 'tb',
                                   'engine_smp.hex'))
OUT = os.path.join(HERE, 'engine_sample_rom.v')

N_FRAME = 128
N_FRAMES = 9

with open(SRC) as f:
    vals = [int(line.strip(), 16) for line in f if line.strip()]

assert len(vals) == N_FRAME * N_FRAMES, f'{SRC}: expect {N_FRAME*N_FRAMES} lines, got {len(vals)}'

lines = []
lines.append('// engine_sample_rom.v —— 由 gen_engine_sample_rom.py 自动生成，勿手改。')
lines.append('// 9 帧 × 128 样本（int8 补码），同步读 1 拍延迟；帧序与 tb_engine_top 相同。')
lines.append('module engine_sample_rom (')
lines.append('  input  wire              clk,')
lines.append('  input  wire [10:0]       addr,   // {frame[3:0], smp[6:0]}')
lines.append('  output reg  signed [7:0] dout')
lines.append(');')
lines.append('  reg signed [7:0] mem [0:%d];' % (len(vals) - 1))
lines.append('  initial begin')
for i, v in enumerate(vals):
    lines.append('    mem[%4d] = 8\'sh%02x;' % (i, v))
lines.append('  end')
lines.append('  always @(posedge clk) dout <= mem[addr];')
lines.append('endmodule')

with open(OUT, 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f'wrote {OUT}: {len(vals)} samples ({N_FRAMES} frames x {N_FRAME})')
