#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Conv2 权重/偏置/阈值生成器（当前：固定种子合成占位权重）

Conv2 形状（与训练端 snn_conv.py 对齐）：
    输入  = Conv1 LIF 输出（8 通道 × 128 位置）经 OR 池化（相邻两位置相或）→ 8 × 64
    卷积  = Conv1d(8→16, k=5, p=2)    每个输出位置 j：
            x[o][j] = b[o] + Σ_{i=0..7} Σ_{k=0..4} W[o][i][k] · p[t][i][j+k-2]
    LIF   = 纯 IF + 软复位（与 lif_neuron / conv1_array 同一套规则）
    输出  = 16 通道 × 64 位置 × 16 步

为什么先用合成权重：
  与 Conv1 相同——先把 "Conv1 脉冲 → OR 池化 → Conv2 阵列 → LIF → 输出" 的整条
  通路和判分台打通。真实 checkpoint 导出（`src/export/`）做好后只换数值来源，
  ROM 地址布局 / RTL / 判分台都不变。

真实导出的定点规则（README 契约 v0.1）：
    s_w    = max|W_conv2| / 127
    W_int  = round(W / s_w)      ∈ [-128, 127]
    b_int  = round(b / s_w)
    th_int = round(th / s_w)     （>= 1）

产出两个文件（必须一起用）：
  rtl/conv2_wrom.v      : 权重同步 ROM（640 项）+ 偏置/阈值组合 ROM
  tb/conv2_weights.txt  : 纯文本，供 gen_conv2_vectors.py 读

ROM 地址布局：
  addr_w = (o*CI + i)*K + k       0 .. 639
  addr_b = o                      0 .. 15
  addr_t = o                      0 .. 15
"""

import os
import random

CI, CO, K = 8, 16, 5
W_BITS = 8
ADDR_W = 10                     # 640 项 -> 10 位
ADDR_BT = 4                     # 16 项 -> 4 位

rng = random.Random(20261020)

# 合成 int8 权重：按输出通道轮换 4 种模式，保证判分台同时覆盖
#   mode 0: 全正 + 偏置正 → 密集发放
#   mode 1: 全负 + 偏置负 → 永不发（结构锚点）
#   mode 2: 随机正负     → 稀疏/中密度
#   mode 3: 交替正负     → 稀疏
W = [[[0] * K for _ in range(CI)] for _ in range(CO)]
for o in range(CO):
    mode = o % 4
    for i in range(CI):
        for k in range(K):
            if mode == 0:
                v = rng.randint(5, 20)
            elif mode == 1:
                v = rng.randint(-20, -5)
            elif mode == 2:
                v = rng.randint(-20, 20)
            else:
                v = 20 if (i + k) % 2 == 0 else -20
            W[o][i][k] = v

# 故意放几个 int8 极值（127 / -128），覆盖符号与位宽边界
W[0][0][0] = 127
W[0][0][1] = -128
W[3][1][2] = -128
W[5][7][4] = 127
W[8][2][3] = -128
W[12][6][0] = 127

# 偏置：±40；通道 1 强制 -40，配合全负权重保证"永不发"
B = [rng.randint(-40, 40) for _ in range(CO)]
B[1] = -40

# 阈值：120..260，让稀疏/密集两种情形都能出现
TH = [rng.randint(120, 260) for _ in range(CO)]

assert all(-128 <= w <= 127 for o in W for i in o for w in i)
assert all(t >= 1 for t in TH)
assert CO == 16 and CI == 8 and K == 5

ROM_ENTRIES = CO * CI * K


def vlit(v):
    """Verilog 16 位有符号字面量。"""
    return f"-16'sd{-v}" if v < 0 else f"16'sd{v}"


here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)               # hw/engine/lif

# ---------------------------------------------------------------------------
# 1) Verilog ROM
# ---------------------------------------------------------------------------
lines = []
lines.append("// 自动生成：tb/gen_conv2_weights.py —— 请勿手改")
lines.append("// Conv2 权重 ROM（占位合成权重；真实导出格式相同）")
lines.append("// 布局：addr_w = (o*8 + i)*5 + k，共 640 项；addr_b / addr_t = o（各 16 项）")
lines.append("// 权重用同步 ROM（640 项太大，组合 case 会摊成大量 LUT）；")
lines.append("// 偏置/阈值只有 16 项，用组合 case 即可。")
lines.append("")
lines.append("module conv2_wrom (")
lines.append("  input  wire              clk,")
lines.append("  input  wire [9:0]        addr_w,")
lines.append("  input  wire [3:0]        addr_b,")
lines.append("  input  wire [3:0]        addr_t,")
lines.append("  output reg  signed [15:0] dout_w,")
lines.append("  output reg  signed [15:0] dout_b,")
lines.append("  output reg  signed [15:0] dout_t")
lines.append(");")
lines.append("")
lines.append("  reg signed [15:0] wmem [0:639];")
lines.append("")
lines.append("  initial begin")
for o in range(CO):
    for i in range(CI):
        for k in range(K):
            a = (o * CI + i) * K + k
            lines.append(f"    wmem[{a}] = {vlit(W[o][i][k])};  // W[{o}][{i}][{k}]")
lines.append("  end")
lines.append("")
lines.append("  always @(posedge clk)")
lines.append("    dout_w <= wmem[addr_w];")
lines.append("")
lines.append("  always @(*) begin")
lines.append("    case (addr_b)")
for o in range(CO):
    lines.append(f"      4'd{o}: dout_b = {vlit(B[o])};  // B[{o}]")
lines.append("      default: dout_b = 16'sd0;")
lines.append("    endcase")
lines.append("")
lines.append("    case (addr_t)")
for o in range(CO):
    lines.append(f"      4'd{o}: dout_t = {vlit(TH[o])};  // TH[{o}]")
lines.append("      default: dout_t = 16'sd0;")
lines.append("    endcase")
lines.append("  end")
lines.append("")
lines.append("endmodule")
lines.append("")

with open(os.path.join(root, "rtl", "conv2_wrom.v"), "w") as f:
    f.write("\n".join(lines))

# ---------------------------------------------------------------------------
# 2) 权重文本（Python 金标准）
# ---------------------------------------------------------------------------
with open(os.path.join(here, "conv2_weights.txt"), "w") as f:
    f.write("# 自动生成：gen_conv2_weights.py —— 请勿手改\n")
    f.write("# W o i k val / B o val / T o val\n")
    for o in range(CO):
        for i in range(CI):
            for k in range(K):
                f.write(f"W {o} {i} {k} {W[o][i][k]}\n")
    for o in range(CO):
        f.write(f"B {o} {B[o]}\n")
    for o in range(CO):
        f.write(f"T {o} {TH[o]}\n")

print(f"Conv2 占位权重已生成：{ROM_ENTRIES} 项权重 ROM -> rtl/conv2_wrom.v")
for o in range(CO):
    print(f"  o{o:2d}: b={B[o]:4d}  th={TH[o]:3d}  "
          f"W[{o}][0][:]={W[o][0]}")
