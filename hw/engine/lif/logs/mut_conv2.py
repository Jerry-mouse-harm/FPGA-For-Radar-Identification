#!/usr/bin/env python3
"""Conv2 阵列变异测试：把 rtl/conv2_array.v 改坏，确认判分台能抓到。
用法：cd hw/engine/lif && python logs/mut_conv2.py
"""
import os, subprocess

IVL = "/home/jierui/miniconda3/envs/verilog-sim/bin/iverilog"
VVP = "/home/jierui/miniconda3/envs/verilog-sim/bin/vvp"
SRC = "rtl/conv2_array.v"

MUTS = [
    # ---- LIF 规则 ----
    ("L1_GE_to_GT", "wire s_next = (v_sat >= th_q);",
     "wire s_next = (v_sat >  th_q);"),
    ("L2_hard_reset",
     "wire signed [VW-1:0] v_new = s_next ? (v_sat - th_q) : v_sat;",
     "wire signed [VW-1:0] v_new = s_next ? {VW{1'b0}} : v_sat;"),
    ("L3_no_soft_reset", "(v_sat - th_q)", "v_sat"),
    ("L4_no_group_reset",
     "// 新位置组：膜电位从 0 开始（LIF 初始状态）\n          v[l] <= {VW{1'b0}};",
     "// 新位置组：膜电位从 0 开始（LIF 初始状态）\n          v[l] <= v[l];"),
    # ---- 池化 / 窗口 ----
    ("S1_pool_or_to_xor",
     "assign pooled[p] = in_spike[2*p] | in_spike[2*p+1];",
     "assign pooled[p] = in_spike[2*p] ^ in_spike[2*p+1];"),
    ("S2_pad_shift",
     "wire [PW+3:0] win     = vec_pad[g_q*PW +: PW+4];",
     "wire [PW+3:0] win     = vec_pad[g_q*PW+1 +: PW+4];"),
    ("S3_lane_shift", "wire [4:0] w5   = win[l +: 5];",
     "wire [4:0] w5   = win[l+1 +: 5];"),
    ("S4_tap_reverse", "wire       wbit = w5[tap_q];",
     "wire       wbit = w5[4 - tap_q];"),
    # ---- 累加 ----
    ("A1_bias_each_tap",
     "else if (!last_sub)\n            acc[l] <= acc[l] + wsel;",
     "else if (!last_sub)\n            acc[l] <= acc[l] + wsel + bias_q;"),
    # ---- 权重 ROM 时序 ----
    ("W1_grp_not_advanced", "rom_addr_w <= w_base_oc + 1'b1;",
     "rom_addr_w <= w_base_oc;"),
    ("W2_wrap_off", "wire [WA-1:0] w_last_addr = w_base_oc + (CI * K - 1);",
     "wire [WA-1:0] w_last_addr = w_base_oc + (CI * K - 2);"),
    # ---- 输入缓冲时序 ----
    ("I1_prefetch_late", "if (tap_q == K-2)", "if (tap_q == K-1)"),
    ("I2_ic_stuck", ": {ic_q + 3'd1, step_q};", ": {ic_q, step_q};"),
    # ---- 输出 ----
    ("O1_group_swap",
     "out_ring[T*NP-NP + g_q*PW +: PW] <= spike_next_v;",
     "out_ring[T*NP-NP + (G-1-g_q)*PW +: PW] <= spike_next_v;"),
    ("O2_rotate_up",
     "out_ring <= {out_ring[0 +: NP], out_ring[T*NP-1 : NP]};",
     "out_ring <= {out_ring[T*NP-NP-1 : 0], out_ring[T*NP-1 : T*NP-NP]};"),
]

src = open(SRC).read()
caught = 0
for name, old, new in MUTS:
    cnt = src.count(old)
    if cnt == 0:
        print(f"{name:24s} SKIP: 模式未命中")
        continue
    mut = src.replace(old, new)
    mp = f"/tmp/mut2_{name}.v"
    open(mp, "w").write(mut)
    r = subprocess.run([IVL, "-g2012", "-o", f"/tmp/mut2_{name}.out",
                        "tb/tb_conv2_array.v", mp, "rtl/conv2_wrom.v"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{name:24s} COMPILE-ERROR\n{r.stderr[:400]}")
        continue
    sim = subprocess.run([VVP, f"/tmp/mut2_{name}.out"], capture_output=True, text=True)
    out = sim.stdout + sim.stderr
    caught_this = "PASS" not in out
    if caught_this:
        caught += 1
    line = next((l for l in out.splitlines()
                 if "FAIL (" in l or "TIMEOUT" in l or "PASS (" in l), "")
    print(f"{name:24s} {'FAIL(caught)' if caught_this else 'PASS(未抓到!)'}  {line.strip()}")

print(f"\n变异捕获：{caught}/{len(MUTS)}")
for f in os.listdir("/tmp"):
    if f.startswith("mut2_") and (f.endswith(".v") or f.endswith(".out")):
        os.remove(os.path.join("/tmp", f))
