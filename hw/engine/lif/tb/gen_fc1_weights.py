#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FC1 / 读出层权重生成器（当前：固定种子合成占位权重）

形状（与训练端 snn_conv.py 对齐）：
    Conv2 输出 (16 通道 × 64 位置 × 16 步)
      → OR 池化 64→32            p[t][o][j] = s2[t][o][2j] | s2[t][o][2j+1]
      → flatten (16×32=512)      c = o*32 + j（与 PyTorch flatten(1) 一致）
      → FC1 Linear(512→32) + LIF3（纯 IF + 软复位）
      → 读出层 Linear(32→5)，按 T 步脉冲计数：
            logits[c] = Σ_r W2[c][r]·count[r] + B2[c]·T

为什么先用合成权重：
  与 Conv1/Conv2 相同——先把 "Conv2 脉冲 → 池化 → FC1 → 读出 argmax" 的
  整条通路和判分台打通。真实 checkpoint 导出后只换数值来源，ROM 布局 / RTL /
  判分台都不变（`python src/export/export_int8.py --install` 时同步替换本文件的产出）。

真实导出的定点规则（README 契约 v0.1）：
    s_w = max|W| / 127；W_int = round(W/s_w) ∈ [-128,127]
    b_int = round(b/s_w)；th_int = max(1, round(th/s_w))（FC1/F​C2 各自独立）

产出三个文件（必须一起用）：
  rtl/fc1_wrom.v      : FC1 权重 ROM（512 地址 × 32 神经元 × int8，8 个 BSRAM 银行）
                        + 偏置/阈值常量（每神经元 16 bit，无地址）
  rtl/readout_wrom.v  : 读出层权重组合 ROM（32 项 × 5 类 × int8）+ 5 个偏置常量
  tb/fc1_weights.txt  : 纯文本，供 gen_fc_vectors.py 读

ROM 布局：
  fc1 权重：addr = c（0..511，c = o*32+j）；dout_w[8*r +: 8] = W1[r][c]
            bank j 的 32 位字 = {W[4j+3], W[4j+2], W[4j+1], W[4j]}（字节 q = 神经元 4j+q）
  读出层：  addr = r（0..31）；dout_w[8*c +: 8] = W2[c][r]
"""

import os
import random

NR, NIN = 32, 512          # FC1 神经元数 / 输入数
NC = 5                     # 类别数
T = 16
BANKS = NR // 4            # 每个 32-bit 字装 4 个 int8 权重

rng = random.Random(20261021)

# ---------------------------------------------------------------------------
# FC1 占位权重：4 种模式轮换，保证判分台同时覆盖
#   mode 0: 全正 + 正偏置 → 密集发放
#   mode 1: 全负 + 负偏置 → 永不发（结构锚点）
#   mode 2: 随机正负     → 稀疏/中密度
#   mode 3: 交替正负     → 稀疏
# ---------------------------------------------------------------------------
W1 = [[0] * NIN for _ in range(NR)]
for r in range(NR):
    mode = r % 4
    for c in range(NIN):
        if mode == 0:
            v = rng.randint(5, 20)
        elif mode == 1:
            v = rng.randint(-20, -5)
        elif mode == 2:
            v = rng.randint(-20, 20)
        else:
            v = 20 if (c & 1) == 0 else -20
        W1[r][c] = v

# 故意放几个 int8 极值（127 / -128），覆盖符号与位宽边界
W1[0][0] = 127
W1[0][1] = -128
W1[4][100] = -128
W1[8][255] = 127
W1[12][511] = -128
W1[16][32] = 127

# 偏置刻意压小：16 步静默输入下 |b|·T < 阈值，保证"零帧"真的零发放
# （真实部署权重 |b_int| ≤ 13、th_int=271，也是同样的量级关系）。
B1 = [0] * NR
for r in range(NR):
    if r % 4 == 0:
        B1[r] = rng.randint(5, 9)
    elif r % 4 == 1:
        B1[r] = rng.randint(-40, -20)
    elif r % 4 == 2:
        B1[r] = rng.randint(-8, 8)
    else:
        B1[r] = 0

# 与真实导出保持一致：LIF 阈值是逐层标量（所有神经元相同）
TH1 = 160

# 读出层：随机 int8 权重；偏置刻意让 class 3 / class 4 在"零发放帧"打平
# → 金标准必须取较小索引 3（抓 argmax 的 > / >= 平局语义）
W2 = [[rng.randint(-30, 30) for _ in range(NR)] for _ in range(NC)]
B2 = [-30, -20, -10, 15, 15]

assert all(-128 <= w <= 127 for row in W1 for w in row)
assert all(-128 <= w <= 127 for row in W2 for w in row)
assert TH1 >= 1
assert NR == 32 and NIN == 512 and NC == 5


def vlit16(v):
    """Verilog 16 位有符号字面量。"""
    return f"-16'sd{-v}" if v < 0 else f"16'sd{v}"


here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)               # hw/engine/lif

# ---------------------------------------------------------------------------
# 1) rtl/fc1_wrom.v
# ---------------------------------------------------------------------------
lines = [
    "// 自动生成：tb/gen_fc1_weights.py —— 请勿手改",
    "// FC1 权重 ROM（占位合成权重；真实导出格式相同）",
    f"// 布局：addr_w = c（0..{NIN-1}，c = o*32+j）；dout_w[8*r +: 8] = W1[r][c]",
    f"// {BANKS} 个银行 × {NIN} × 32 bit（每字 4 个 int8 神经元权重）；同步读、1 拍延迟。",
    "// 偏置/阈值是每神经元常量，直接 assign，不占存储。",
    "",
    "module fc1_wrom (",
    "  input  wire               clk,",
    "  input  wire [8:0]         addr_w,",
    "  output wire [255:0]       dout_w,",
    "  output wire signed [511:0] dout_b,",
    "  output wire signed [511:0] dout_t",
    ");",
    "",
]
for j in range(BANKS):
    lines.append(f"  reg [31:0] bank{j} [0:{NIN-1}];")
lines.append("")
lines.append("  initial begin")
for j in range(BANKS):
    for c in range(NIN):
        word = 0
        for q in range(4):
            r = j * 4 + q
            word |= (W1[r][c] & 0xFF) << (8 * q)
        lines.append(f"    bank{j}[{c}] = 32'h{word:08x};  // "
                     f"W[{j*4}..{j*4+3}][{c}]")
lines.append("  end")
lines.append("")
for j in range(BANKS):
    lines.append(f"  reg [31:0] q{j};")
lines.append("  always @(posedge clk) begin")
for j in range(BANKS):
    lines.append(f"    q{j} <= bank{j}[addr_w];")
lines.append("  end")
lines.append("")
lines.append("  assign dout_w = {" + ", ".join(f"q{j}" for j in range(BANKS - 1, -1, -1)) + "};")
lines.append("")
lines.append("  assign dout_b = {" +
             ", ".join(vlit16(B1[r]) for r in range(NR - 1, -1, -1)) + "};")
lines.append("  assign dout_t = {" +
             ", ".join(vlit16(TH1) for _ in range(NR)) + "};")
lines.append("")
lines.append("endmodule")
lines.append("")

with open(os.path.join(root, "rtl", "fc1_wrom.v"), "w") as f:
    f.write("\n".join(lines))

# ---------------------------------------------------------------------------
# 2) rtl/readout_wrom.v
# ---------------------------------------------------------------------------
lines = [
    "// 自动生成：tb/gen_fc1_weights.py —— 请勿手改",
    "// 读出层权重 ROM（占位合成权重；真实导出格式相同）",
    "// addr = r（0..31）；dout_w[8*c +: 8] = W2[c][r]；只有 32 项，用组合 case。",
    "",
    "module readout_wrom (",
    "  input  wire [4:0]       addr_r,",
    "  output reg  [39:0]      dout_w,",
    "  output wire signed [79:0] dout_b",
    ");",
    "",
    "  always @(*) begin",
    "    case (addr_r)",
]
for r in range(NR):
    word = 0
    for c in range(NC):
        word |= (W2[c][r] & 0xFF) << (8 * c)
    lines.append(f"      5'd{r}: dout_w = 40'h{word:010x};  // W2[0..4][{r}]")
lines += [
    "      default: dout_w = 40'sd0;",
    "    endcase",
    "  end",
    "",
    "  assign dout_b = {" +
    ", ".join(vlit16(B2[c]) for c in range(NC - 1, -1, -1)) + "};",
    "",
    "endmodule",
    "",
]

with open(os.path.join(root, "rtl", "readout_wrom.v"), "w") as f:
    f.write("\n".join(lines))

# ---------------------------------------------------------------------------
# 3) tb/fc1_weights.txt（Python 金标准读这个）
# ---------------------------------------------------------------------------
with open(os.path.join(here, "fc1_weights.txt"), "w") as f:
    f.write("# 自动生成：gen_fc1_weights.py —— 请勿手改\n")
    f.write("# W1 r c val / B1 r val / T1 r val / W2 c r val / B2 c val\n")
    for r in range(NR):
        for c in range(NIN):
            f.write(f"W1 {r} {c} {W1[r][c]}\n")
    for r in range(NR):
        f.write(f"B1 {r} {B1[r]}\n")
    for r in range(NR):
        f.write(f"T1 {r} {TH1}\n")
    for c in range(NC):
        for r in range(NR):
            f.write(f"W2 {c} {r} {W2[c][r]}\n")
    for c in range(NC):
        f.write(f"B2 {c} {B2[c]}\n")

print(f"FC1 占位权重已生成：{NR}×{NIN} 权重 -> rtl/fc1_wrom.v（{BANKS} 个 BSRAM 银行）")
print(f"读出层 {NC}×{NR} -> rtl/readout_wrom.v；文本 tb/fc1_weights.txt")
for r in range(0, NR, 4):
    print(f"  r{r:2d}/{r+1:2d}/{r+2:2d}/{r+3:2d}: b={B1[r]:4d}  th={TH1}  "
          f"W[{r}][0:4]={W1[r][0:5]}")
print(f"  B2={B2}（零发放帧 class 3/4 平局 → 期望 class 3）")
