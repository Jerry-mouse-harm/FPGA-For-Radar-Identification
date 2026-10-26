#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LIF 神经元金标准生成器（纯整数，不依赖 torch）

产出 tb/ 下四个 hex（每行一个数，iverilog $readmemh 读）：
  th.hex        : NC 行，每个用例的整数阈值（16 位二补码）
  x.hex         : NC*T 行，每步输入加权和（16 位二补码）
  spike_exp.hex : NC*T 行，本步是否发放（0/1）
  v_exp.hex     : NC*T 行，本步更新后的膜电位（16 位二补码）

金标准模型与 rtl/lif_neuron.v 逐位一致：
    v = sat16(v + x)        # 先加、再饱和
    s = (v >= th)           # 是 >=，不是 >
    v = v - th if s else v  # 软复位，只减一次

用例设计目标 = 抓硬件最可能犯的错：
    阈值边界（>= / >、off-by-one）、慢积分、单步多发、正负混合且不泄漏、
    双向饱和、阈值上限的"撞线/差一点"、阈值 1、长时间零输入（必须不泄漏）、随机序列。
"""

import os
import random

NC = 24
T = 16
VMAX = 32767
VMIN = -32768


def sat16(v):
    return max(VMIN, min(VMAX, v))


def model(th, xs):
    """整数域 IF 模型，返回 [(spike, v_after), ...]"""
    v = 0
    out = []
    for x in xs:
        v = sat16(v + x)
        s = 1 if v >= th else 0
        if s:
            v -= th
        out.append((s, v))
    return out


# ---------------------------------------------------------------------------
# 用例表
# ---------------------------------------------------------------------------
CASES = []


def case(name, th, xs):
    assert len(xs) == T, f"{name}: 需要 {T} 步，实际 {len(xs)}"
    assert 1 <= th <= VMAX, f"{name}: 阈值 {th} 超出 [1, {VMAX}]"
    assert all(VMIN <= x <= VMAX for x in xs), f"{name}: 输入超界"
    CASES.append((name, th, xs))


# --- 阈值边界 ---
case("idle_zero",        100, [0] * 16)
case("just_below",       100, [6] * 16)            # 16*6=96，攒满也不到 100
case("exact_th",         100, [100] * 16)          # 每步撞线：抓 v > th 的错
case("slow_ramp_10",     100, [10] * 16)           # 只在 t=9 发
case("ramp_7",           100, [7] * 16)            # 只在 t=14 发
case("multi_30",         100, [30] * 16)           # 5 发，软复位后余数要对
case("multi_64",         100, [64] * 16)           # 6 发，相位不规则
# --- 正负混合 / 软复位余数 ---
case("negative_drive",   100, [-50] * 16)
case("mixed_sign",       500,
     [300, -200, 700, -100, 0, 450, -600, 800,
      100, -300, 550, -50, 1200, -900, 200, 600])
case("neg_then_pos",     200, [-300] * 4 + [500] * 4 + [0] * 8)
case("no_leak",          100, [150] + [0] * 15)    # 发完 v=50，之后必须一直 50
# --- 饱和 ---
case("sat_pos",          100, [32767] * 16)
case("sat_neg",          100, [-32768] * 16)
case("sat_recover",     1000,
     [-32768] * 3 + [32767] * 3 + [0] * 4 + [-2000] * 3 + [2500] * 3)
# --- 阈值上限撞线 / 差一点 ---
case("th_max_hit",     VMAX, [2048] * 16)          # t=15: 32768 >= 32767
case("th_max_miss",    VMAX, [2047] * 16)          # 32752 < 32767
case("th_8000_exact",   8000, [500] * 16)          # t=15 正好 8000
# --- 阈值 1 / 每步发 ---
case("th_one",             1, [0, 1, -1, 2, 0, -5, 3, 1, 0, 0, 7, -2, 0, 4, -1, 2])
case("spike_every_one",    1, [1] * 16)
# --- 大幅摆动 ---
case("big_alt",         4000, [3000, -3000] * 8)
# --- 随机（固定种子，逐字节可复现）---
_rng = random.Random(20261018)
for k in range(4):
    th = _rng.randint(64, 5000)
    xs = [_rng.randint(-4000, 4000) for _ in range(T)]
    case(f"random_{k}", th, xs)

assert len(CASES) == NC, f"用例数应为 {NC}，实际 {len(CASES)}"


# ---------------------------------------------------------------------------
# 自检锚点（模型本身先验一遍，防止生成器写错还生成"错的金标准"）
# ---------------------------------------------------------------------------
def spikes_of(name):
    _, th, xs = next(c for c in CASES if c[0] == name)
    return [s for s, _ in model(th, xs)]


assert spikes_of("idle_zero") == [0] * 16
assert spikes_of("just_below") == [0] * 16
assert spikes_of("exact_th") == [1] * 16
assert spikes_of("slow_ramp_10") == [0] * 9 + [1] + [0] * 6
assert spikes_of("ramp_7") == [0] * 14 + [1] + [0]
assert spikes_of("th_max_hit")[-1] == 1 and sum(spikes_of("th_max_hit")) == 1
assert spikes_of("th_max_miss") == [0] * 16
assert spikes_of("th_8000_exact")[-1] == 1 and sum(spikes_of("th_8000_exact")) == 1
assert spikes_of("sat_pos") == [1] * 16
assert spikes_of("sat_neg") == [0] * 16
assert spikes_of("spike_every_one") == [1] * 16

_, th_sl, xs_sl = next(c for c in CASES if c[0] == "slow_ramp_10")
assert model(th_sl, xs_sl)[9] == (1, 0)            # t=9: v=100，发完正好 0

_, th_sp, xs_sp = next(c for c in CASES if c[0] == "sat_pos")
assert model(th_sp, xs_sp)[-1][1] == VMAX - 100    # 饱和 32767 − 100 = 32667

_, th_nl, xs_nl = next(c for c in CASES if c[0] == "no_leak")
v_no_leak = model(th_nl, xs_nl)[-1][1]
assert v_no_leak == 50, v_no_leak                  # 15 步零输入后仍是 50

_, th_sn, xs_sn = next(c for c in CASES if c[0] == "sat_neg")
assert model(th_sn, xs_sn)[-1][1] == VMIN          # 负向钉死 -32768


# ---------------------------------------------------------------------------
# 写 hex
# ---------------------------------------------------------------------------
def h16(v):
    return f"{v & 0xFFFF:04x}"


here = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(here, "th.hex"), "w") as f:
    for _, th, _ in CASES:
        f.write(h16(th) + "\n")

with open(os.path.join(here, "x.hex"), "w") as f:
    for _, _, xs in CASES:
        for x in xs:
            f.write(h16(x) + "\n")

with open(os.path.join(here, "spike_exp.hex"), "w") as f:
    for _, th, xs in CASES:
        for s, _ in model(th, xs):
            f.write(f"{s:x}\n")

with open(os.path.join(here, "v_exp.hex"), "w") as f:
    for _, th, xs in CASES:
        for _, v in model(th, xs):
            f.write(h16(v) + "\n")

print(f"生成 {NC} 用例 x {T} 步 -> tb/{{th,x,spike_exp,v_exp}}.hex")
print("锚点自检通过：")
print("  exact_th         每步发        (v >= th 边界)")
print("  slow_ramp_10     t=9 单发      (攒到 100 恰好撞线)")
print("  ramp_7           t=14 单发     (off-by-one 探针)")
print("  sat_pos          每步发, 末步 v=32667  (饱和 - th)")
print("  sat_neg          全程不发, v=-32768")
print(f"  th_max_hit       t=15 单发；th_max_miss 全程不发 (32752 vs 32767)")
print(f"  no_leak          15 步零输入后 v 仍为 50 (无泄漏)")
print("用例：")
for i, (name, th, _) in enumerate(CASES):
    print(f"  [{i:2d}] {name:<16s} th={th}")
