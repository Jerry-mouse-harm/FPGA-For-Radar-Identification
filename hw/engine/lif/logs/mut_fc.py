#!/usr/bin/env python3
"""FC1 阵列 + 读出层变异测试：把 RTL 改坏，确认判分台能抓到。
用法：cd hw/engine/lif && python logs/mut_fc.py
"""
import os, subprocess

IVL = "/home/jierui/miniconda3/envs/verilog-sim/bin/iverilog"
VVP = "/home/jierui/miniconda3/envs/verilog-sim/bin/vvp"

# (文件, 名称, old, new)
MUTS = [
    # ================= rtl/fc1_array.v =================
    ("rtl/fc1_array.v", "L1_GE_to_GT",
     "wire s_next = (v_sat >= th_l);",
     "wire s_next = (v_sat >  th_l);"),
    ("rtl/fc1_array.v", "L2_hard_reset",
     "wire signed [VW-1:0] v_new = s_next ? (v_sat - th_l) : v_sat;",
     "wire signed [VW-1:0] v_new = s_next ? {VW{1'b0}} : v_sat;"),
    ("rtl/fc1_array.v", "L3_no_soft_reset", "(v_sat - th_l)", "v_sat"),
    ("rtl/fc1_array.v", "L4_no_frame_v_reset",
     "          for (gg = 0; gg < NG; gg = gg + 1) v[gg] <= {VW{1'b0}};\n"
     "        end else if (state == S_ACC) begin",
     "          for (gg = 0; gg < NG; gg = gg + 1) v[gg] <= v[gg];\n"
     "        end else if (state == S_ACC) begin"),
    ("rtl/fc1_array.v", "L5_no_saturation",
     "wire signed [VW-1:0] v_sat = (vsum > VMAX) ? VMAX :\n"
     "                                   (vsum < VMIN) ? VMIN : vsum[VW-1:0];",
     "wire signed [VW-1:0] v_sat = vsum[VW-1:0];"),
    # ---- 池化 / 位提取 ----
    ("rtl/fc1_array.v", "S1_pool_or_to_xor",
     "assign pooled[p] = in_spike[2*p] | in_spike[2*p+1];",
     "assign pooled[p] = in_spike[2*p] ^ in_spike[2*p+1];"),
    ("rtl/fc1_array.v", "S2_bit_sr_load_off",
     "bit_sr <= {1'b0, rd_data[NP-1:1]};",
     "bit_sr <= {1'b0, rd_data[NP-2:0]};"),
    ("rtl/fc1_array.v", "S3_bit_sr_shift_off",
     "bit_sr <= {1'b0, bit_sr[NP-1:1]};",
     "bit_sr <= {1'b0, bit_sr[NP-2:0]};"),
    # ---- 输入缓存时序 ----
    ("rtl/fc1_array.v", "I1_ch_prefetch_late",
     "if (c_q[LB-1:0] == NP-2)", "if (c_q[LB-1:0] == NP-1)"),
    ("rtl/fc1_array.v", "I2_no_step_prefetch",
     "? ((step_q == T-1) ? {MADDR{1'b0}} : {4'd0, step_q + 4'd1})",
     "? ((step_q == T-1) ? {MADDR{1'b0}} : {4'd0, step_q})"),
    ("rtl/fc1_array.v", "I2b_no_pass_rewind",
     ": {4'd0, step_q};",
     ": {4'd1, step_q};"),
    ("rtl/fc1_array.v", "I3_wr_addr_swap",
     "if (wr_en) in_mem[{in_ch, in_step}] <= pooled;",
     "if (wr_en) in_mem[{in_step, in_ch}] <= pooled;"),
    # ---- 权重 ROM 时序 ----
    ("rtl/fc1_array.v", "W1_no_rom_prefetch",
     "w_addr  <= {{(WA-1){1'b0}}, 1'b1};",
     "w_addr  <= {WA{1'b0}};"),
    ("rtl/fc1_array.v", "W2_lane_byte_reverse",
     "wire signed [7:0] w_byte = w_rom[8*r_sel +: 8];",
     "wire signed [7:0] w_byte = w_rom[8*(NR-1-r_sel) +: 8];"),
    # ---- 累加 ----
    ("rtl/fc1_array.v", "A1_double_bias",
     "else\n            acc <= acc + wsel;",
     "else\n            acc <= acc + wsel + b_l;"),
    ("rtl/fc1_array.v", "A2_no_bias", "acc <= b_l + wsel;", "acc <= wsel;"),
    ("rtl/fc1_array.v", "A3_last_weight_lost",
     "else\n            acc <= acc + wsel;",
     "else if (c_q != NIN-1)\n            acc <= acc + wsel;"),
    # ---- 输出时序 / 分组 ----
    ("rtl/fc1_array.v", "O1_spk_bit_reverse",
     "spk_vec[g_q*LP +: LP] <= spike_next_v;",
     "spk_vec[(NG-1-g_q)*LP +: LP] <= spike_next_v;"),
    ("rtl/fc1_array.v", "O1b_group_never_advances",
     "g_q   <= g_q + 1'b1;\n            state <= S_STEP_START;",
     "g_q   <= g_q;\n            state <= S_STEP_START;"),
    ("rtl/fc1_array.v", "O2_frame_done_early",
     "if (step_q == T-1) begin\n              frame_done <= 1'b1;",
     "if (step_q == T-2) begin\n              frame_done <= 1'b1;"),

    # ================= rtl/readout.v =================
    ("rtl/readout.v", "R1_argmax_tie_ge",
     "if (cand[ci] > best) begin", "if (cand[ci] >= best) begin"),
    ("rtl/readout.v", "R2_no_bias",
     "cand[ci] = acc[ci] + ({{(LW-TW){b_const[TW*ci + TW - 1]}},\n"
     "                             b_const[TW*ci +: TW]} <<< TSH);",
     "cand[ci] = acc[ci];"),
    ("rtl/readout.v", "R3_bias_not_times_T",
     "b_const[TW*ci +: TW]} <<< TSH);", "b_const[TW*ci +: TW]});"),
    ("rtl/readout.v", "R4_w_byte_reverse",
     "acc[j] + {{(LW-8){w_row[8*j + 7]}}, w_row[8*j +: 8]};",
     "acc[j] + {{(LW-8){w_row[8*(NC-1-j) + 7]}}, w_row[8*(NC-1-j) +: 8]};"),
    ("rtl/readout.v", "R5_shift_direction",
     "sr_q <= {1'b0, sr_q[NR-1:1]};",
     "sr_q <= {sr_q[NR-2:0], 1'b0};"),
    ("rtl/readout.v", "R6_no_frame_clear",
     "step_cnt <= 5'd0;\n        for (j = 0; j < NC; j = j + 1) acc[j] <= {LW{1'b0}};",
     "step_cnt <= step_cnt;\n        for (j = 0; j < NC; j = j + 1) acc[j] <= acc[j];"),
    ("rtl/readout.v", "R7_busy_stuck",
     "r_q  <= 5'd0;\n            busy <= 1'b0;",
     "r_q  <= 5'd0;\n            busy <= busy;"),
    ("rtl/readout.v", "R8_done_every_step",
     "done <= 1'b0;                  // 默认单拍脉冲",
     "done <= (state == S_ACC && r_q == NR-1);"),
    ("rtl/readout.v", "R9_step_off",
     "if (step_cnt == T-1) begin", "if (step_cnt == T-2) begin"),
]

srcs = {}
for f, name, old, new in MUTS:
    if f not in srcs:
        srcs[f] = open(f).read()

caught = 0
for f, name, old, new in MUTS:
    src = srcs[f]
    if src.count(old) == 0:
        print(f"{name:24s} SKIP: 模式未命中 ({f})")
        continue
    mut = src.replace(old, new)
    mp = f"/tmp/mutf_{name}.v"
    open(mp, "w").write(mut)
    if "fc1_array" in f:
        args = ["tb/tb_fc1_array.v", mp, "rtl/fc1_wrom.v"]
    else:
        args = ["tb/tb_readout.v", mp, "rtl/readout_wrom.v"]
    r = subprocess.run([IVL, "-g2012", "-o", f"/tmp/mutf_{name}.out"] + args,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{name:24s} COMPILE-ERROR\n{r.stderr[:400]}")
        continue
    sim = subprocess.run([VVP, f"/tmp/mutf_{name}.out"], capture_output=True, text=True)
    out = sim.stdout + sim.stderr
    caught_this = "PASS" not in out
    if caught_this:
        caught += 1
    line = next((l for l in out.splitlines()
                 if "FAIL (" in l or "TIMEOUT" in l or "PASS (" in l), "")
    print(f"{name:24s} {'FAIL(caught)' if caught_this else 'PASS(未抓到!)'}  {line.strip()}")

print(f"\n变异捕获：{caught}/{len(MUTS)}")
for f in os.listdir("/tmp"):
    if f.startswith("mutf_") and (f.endswith(".v") or f.endswith(".out")):
        os.remove(os.path.join("/tmp", f))
