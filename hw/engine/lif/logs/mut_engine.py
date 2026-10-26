#!/usr/bin/env python3
"""引擎顶层互连变异测试：把 rtl/engine_top.v 接缝改坏，确认判分台能抓到。
用法：cd hw/engine/lif && python logs/mut_engine.py
"""
import os, subprocess

IVL = "/home/jierui/miniconda3/envs/verilog-sim/bin/iverilog"
VVP = "/home/jierui/miniconda3/envs/verilog-sim/bin/vvp"

# (文件, 名称, old, new)
MUTS = [
    # ---- 编码前端 → Conv1 ----
    ("rtl/engine_top.v", "E1_conv1_valid_from_done",
     ".in_valid  (fe_step_valid),", ".in_valid  (fe_done),"),
    ("rtl/engine_top.v", "E2_fe_spike_rotate",
     ".in_spike  (fe_spike),",
     ".in_spike  ({fe_spike[0], fe_spike[N-1:1]}),"),

    # ---- Conv1 → Conv2 ----
    ("rtl/engine_top.v", "E3_conv2_valid_from_fe",
     ".in_valid  (c1_out_valid),", ".in_valid  (fe_step_valid),"),
    ("rtl/engine_top.v", "E4_conv2_ch_step_swap",
     ".in_ch     (c1_out_ch),\n    .in_step   (c1_out_step),",
     ".in_ch     (c1_out_step),\n    .in_step   (c1_out_ch),"),
    ("rtl/engine_top.v", "E5_conv2_spike_rotate",
     ".in_spike  (c1_out_spike),",
     ".in_spike  ({c1_out_spike[0], c1_out_spike[N-1:1]}),"),

    # ---- Conv2 → FC1 ----
    ("rtl/engine_top.v", "E6_fc1_ch_step_swap",
     ".in_ch       (c2_out_ch),\n    .in_step     (c2_out_step),",
     ".in_ch       (c2_out_step[2:0]),\n    .in_step     ({1'b0, c2_out_ch}),"),
    ("rtl/engine_top.v", "E7_fc1_valid_from_c2_ch0",
     ".in_valid    (c2_out_valid),", ".in_valid    (c2_out_ch[0]),"),

    # ---- FC1 → readout ----
    ("rtl/engine_top.v", "E8_readout_valid_from_fs",
     ".in_valid    (f1_spk_valid),", ".in_valid    (f1_frame_start),"),
    ("rtl/engine_top.v", "E9_readout_spike_invert",
     ".in_spike    (f1_spk_vec),", ".in_spike    (~f1_spk_vec),"),

    # ---- 顶层握手 ----
    ("rtl/engine_top.v", "E10_busy_start_zero",
     "fe_start <= 1'b1;    // 下一拍启动编码前端\n            eng_busy <= 1'b1;",
     "fe_start <= 1'b1;    // 下一拍启动编码前端\n            eng_busy <= 1'b0;"),
    ("rtl/engine_top.v", "E11_done_from_conv1",
     "if (ro_done) begin", "if (c1_done) begin"),
    ("rtl/engine_top.v", "E12_class_constant",
     "eng_class <= ro_cls;", "eng_class <= 3'd0;"),
    ("rtl/engine_top.v", "E13_done_stuck",
     "      fe_start <= 1'b0;          // 默认单拍脉冲\n      eng_done <= 1'b0;",
     "      fe_start <= 1'b0;          // 默认单拍脉冲\n      eng_done <= eng_done;"),
]

SRCS = ["tb/tb_engine_top.v", "rtl/engine_top.v", "../encode_frontend.v",
        "../../verilog_lab/m6_encoder/sample_to_n.v",
        "rtl/conv1_array.v", "rtl/conv1_wrom.v",
        "rtl/conv2_array.v", "rtl/conv2_wrom.v",
        "rtl/fc1_array.v", "rtl/fc1_wrom.v",
        "rtl/readout.v", "rtl/readout_wrom.v"]

srcs = {}
for f, name, old, new in MUTS:
    if f not in srcs:
        srcs[f] = open(f).read()

caught = 0
for f, name, old, new in MUTS:
    src = srcs[f]
    if src.count(old) != 1:
        print(f"{name:26s} SKIP: 模式命中 {src.count(old)} 次 ({f})")
        continue
    mp = f"/tmp/mute_{name}.v"
    open(mp, "w").write(src.replace(old, new))
    args = [mp if s == f else s for s in SRCS]
    r = subprocess.run([IVL, "-g2012", "-o", f"/tmp/mute_{name}.out"] + args,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{name:26s} COMPILE-ERROR\n{r.stderr[:400]}")
        continue
    sim = subprocess.run([VVP, f"/tmp/mute_{name}.out"], capture_output=True, text=True)
    out = sim.stdout + sim.stderr
    caught_this = "PASS" not in out
    if caught_this:
        caught += 1
    line = next((l for l in out.splitlines()
                 if "FAIL (" in l or "TIMEOUT" in l or "PASS (" in l), "")
    print(f"{name:26s} {'FAIL(caught)' if caught_this else 'PASS(未抓到!)'}  {line.strip()}",
          flush=True)

print(f"\n变异捕获：{caught}/{len(MUTS)}")
for f in os.listdir("/tmp"):
    if f.startswith("mute_") and (f.endswith(".v") or f.endswith(".out")):
        os.remove(os.path.join("/tmp", f))
