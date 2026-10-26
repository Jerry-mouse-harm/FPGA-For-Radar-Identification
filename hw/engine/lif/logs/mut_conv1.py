#!/usr/bin/env python3
"""Conv1 阵列变异测试：把 rtl/conv1_array.v 改坏，确认判分台能抓到。
用法：cd hw/engine/lif && python logs/mut_conv1.py
"""
import os, subprocess, sys

IVL = "/home/jierui/miniconda3/envs/verilog-sim/bin/iverilog"
VVP = "/home/jierui/miniconda3/envs/verilog-sim/bin/vvp"
SRC = "rtl/conv1_array.v"

MUTS = [
    ("C1_GE_to_GT", "wire s_next = (v_sat >= th_q);",
     "wire s_next = (v_sat >  th_q);"),
    ("C2_hard_reset",
     "wire signed [VW-1:0] v_new = s_next ? (v_sat - th_q) : v_sat;",
     "wire signed [VW-1:0] v_new = s_next ? {VW{1'b0}} : v_sat;"),
    ("C3_no_ch_reset",
     "begin\n          // 新通道 / 新位置组：膜电位从 0 开始（LIF 初始状态）\n          v[l] <= {VW{1'b0}};",
     "begin\n          v[l] <= v[l];"),
    ("C4_pad_shift",
     "wire [PW+3:0] win    = spk_pad[g_q*PW +: PW+4];",
     "wire [PW+3:0] win    = spk_pad[g_q*PW+2 +: PW+4];"),
    ("C5_group_skip",
     "g_q     <= g_q + 1'b1;", "g_q     <= g_q + 2'd2;"),
    ("C6_quarter_swap",
     "out_ring[T*N-N + g_q*PW +: PW] <= spike_next_v;",
     "out_ring[T*N-N + (G-1-g_q)*PW +: PW] <= spike_next_v;"),
    ("C7_bias_each_tap",
     "else if (tap_q < K-1)\n            acc[l] <= acc[l] + wsel;",
     "else if (tap_q < K-1)\n            acc[l] <= acc[l] + wsel + bias_q;"),
    ("C8_weight_reverse",
     "wire [5:0] rom_addr_w = ch_q * K + tap_q;",
     "wire [5:0] rom_addr_w = ch_q * K + (K-1 - tap_q);"),
    ("C9_no_soft_reset", "(v_sat - th_q)", "v_sat"),
    ("R1_out_rotate_up",
     "{out_ring[0 +: N], out_ring[T*N-1 : N]}",
     "{out_ring[T*N-N-1 : 0], out_ring[T*N-1 : T*N-N]}"),
    ("R2_prefetch_wrong",
     "cur_spk  <= spk_ring[N +: N];", "cur_spk  <= spk_ring[0 +: N];"),
    ("R3_load_slot_wrong",
     "spk_ring <= {in_spike, spk_ring[T*N-1 : N]};",
     "spk_ring <= {spk_ring[T*N-N-1 : 0], in_spike};"),
]

src = open(SRC).read()
caught = 0
for name, old, new in MUTS:
    mut = src
    cnt = mut.count(old)
    if cnt == 0:
        print(f"{name:24s} SKIP: 模式未命中")
        continue
    mut = mut.replace(old, new)
    mp = f"/tmp/mut_{name}.v"
    open(mp, "w").write(mut)
    r = subprocess.run([IVL, "-g2012", "-o", f"/tmp/mut_{name}.out",
                        "tb/tb_conv1_array.v", mp, "rtl/conv1_wrom.v"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{name:24s} COMPILE-ERROR\n{r.stderr[:400]}")
        continue
    sim = subprocess.run([VVP, f"/tmp/mut_{name}.out"], capture_output=True, text=True)
    out = sim.stdout + sim.stderr
    verdict = "PASS(未抓到!)" if "PASS" in out else "FAIL(caught)"
    if "PASS" not in out:
        caught += 1
    # 提取错误数/超时信息
    line = next((l for l in out.splitlines() if "FAIL (" in l or "TIMEOUT" in l or "PASS (" in l), "")
    print(f"{name:24s} {verdict}  {line.strip()}")

print(f"\n变异捕获：{caught}/{len(MUTS)}")
for f in os.listdir("/tmp"):
    if f.startswith("mut_") and (f.endswith(".v") or f.endswith(".out")):
        os.remove(os.path.join("/tmp", f))
