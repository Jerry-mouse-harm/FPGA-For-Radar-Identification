#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Conv1 权重/偏置/阈值生成器（当前：固定种子合成占位权重）

为什么先用合成权重：
  本轮目标是打通 "前端脉冲 → Conv1 阵列 → 权重 ROM → 金标准对拍" 的整条通路。
  真实权重导出（checkpoint → int8）是独立一步，但**输出格式与这里完全一致**，
  到时候只换数值来源，RTL / 判分台都不用改。

真实导出的定点规则（README 契约 v0.1，换成真实权重时照做）：
    s_w       = max|W_conv1| / 127
    W_int     = round(W / s_w)      ∈ [-128, 127]
    b_int     = round(b / s_w)
    th_int    = round(th / s_w)     （>= 1）
  注意：LIF 的膜电位 LSB 就是 s_w，所以 ROM 里只存整数，尺度由软件侧记账。

产出两个文件（必须一起用，保证 RTL 和 Python 模型看到同一组数）：
  rtl/conv1_wrom.v      : case 实现的 3 端口 ROM（权重 / 偏置 / 阈值）
  tb/conv1_weights.txt  : 纯文本，供 gen_conv1_vectors.py 读

ROM 地址布局（6 位，共 56 项）：
  0 .. 39   W[c][k] = c*5 + k
  40.. 47   B[c]     = 40 + c
  48.. 55   TH[c]    = 48 + c
"""

import os
import random

C, K = 8, 5
W_BITS = 8
ADDR_W = 6              # 56 项 -> 6 位

rng = random.Random(20261018)

# 合成 int8 权重：故意放几个极值（127 / -128），覆盖符号与边界
W = [[rng.randint(-127, 127) for _ in range(K)] for _ in range(C)]
W[0][0], W[0][1] = 127, -128
W[3][2] = -128
W[5][4] = 127

# 偏置：真实网络里 b_int 与阈值同尺度，这里取 ±80 保证有正有负
B = [rng.randint(-80, 80) for _ in range(C)]

# 阈值：120..420，让"稀疏输入不出、密集输入出"的两种情形都能出现
TH = [rng.randint(120, 420) for _ in range(C)]

assert all(-128 <= w <= 127 for row in W for w in row)
assert all(t >= 1 for t in TH)

ROM_ENTRIES = C * K + 2 * C


def vlit(v):
    """Verilog 16 位有符号字面量。"""
    return f"-16'sd{-v}" if v < 0 else f"16'sd{v}"


here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)               # hw/engine/lif

# ---------------------------------------------------------------------------
# 1) Verilog ROM
# ---------------------------------------------------------------------------
lines = []
lines.append("// 自动生成：tb/gen_conv1_weights.py —— 请勿手改")
lines.append("// Conv1 权重 ROM（占位合成权重；真实导出格式相同）")
lines.append("// 布局：0..39 = W[c][k]（c*5+k），40..47 = B[c]，48..55 = TH[c]")
lines.append("// 三端口都是组合读（case 实现，不依赖 $readmemh / BSRAM 原语）")
lines.append("")
lines.append("module conv1_wrom (")
lines.append("  input  wire [5:0]        addr_w,")
lines.append("  input  wire [5:0]        addr_b,")
lines.append("  input  wire [5:0]        addr_t,")
lines.append("  output reg  signed [15:0] dout_w,")
lines.append("  output reg  signed [15:0] dout_b,")
lines.append("  output reg  signed [15:0] dout_t")
lines.append(");")
lines.append("")
lines.append("  always @(*) begin")
lines.append("    case (addr_w)")
for c in range(C):
    for k in range(K):
        a = c * K + k
        lines.append(f"      6'd{a}: dout_w = {vlit(W[c][k])};  // W[{c}][{k}]")
lines.append("      default: dout_w = 16'sd0;")
lines.append("    endcase")
lines.append("")
lines.append("    case (addr_b)")
for c in range(C):
    lines.append(f"      6'd{C*K + c}: dout_b = {vlit(B[c])};  // B[{c}]")
lines.append("      default: dout_b = 16'sd0;")
lines.append("    endcase")
lines.append("")
lines.append("    case (addr_t)")
for c in range(C):
    lines.append(f"      6'd{C*K + C + c}: dout_t = {vlit(TH[c])};  // TH[{c}]")
lines.append("      default: dout_t = 16'sd0;")
lines.append("    endcase")
lines.append("  end")
lines.append("")
lines.append("endmodule")
lines.append("")

with open(os.path.join(root, "rtl", "conv1_wrom.v"), "w") as f:
    f.write("\n".join(lines))

# ---------------------------------------------------------------------------
# 2) 权重文本（Python 金标准）
# ---------------------------------------------------------------------------
with open(os.path.join(here, "conv1_weights.txt"), "w") as f:
    f.write("# 自动生成：gen_conv1_weights.py —— 请勿手改\n")
    f.write("# W c k val / B c val / T c val\n")
    for c in range(C):
        for k in range(K):
            f.write(f"W {c} {k} {W[c][k]}\n")
    for c in range(C):
        f.write(f"B {c} {B[c]}\n")
    for c in range(C):
        f.write(f"T {c} {TH[c]}\n")

print(f"Conv1 占位权重已生成：{ROM_ENTRIES} 项 ROM -> rtl/conv1_wrom.v")
for c in range(C):
    print(f"  c{c}: W={W[c]}  b={B[c]:4d}  th={TH[c]:3d}")
