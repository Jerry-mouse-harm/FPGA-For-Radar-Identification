#!/usr/bin/env bash
# sweep_two_stage.sh —— 扫 SNR × WuRx 占空比，产出两级唤醒 A/B 数据表
#
# 用法（在 hw/board 下）：bash gate_demo/sweep_two_stage.sh
# 产物：gate_demo/two_stage_sweep.tsv
#
# 每个 (SNR, 配置) 重新生成 signal_rom.v；脚本结束/中断时自动恢复默认 20dB ROM。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONDA=/home/jierui/miniconda3/envs/verilog-sim
IVL="$CONDA/bin/iverilog"
VVP="$CONDA/bin/vvp"
PY=/home/jierui/miniconda3/bin/python
OUT="$HERE/two_stage_sweep.tsv"

# MINIMAL=1：只跑默认配置 + 关键 SNR（先回答"值不值"）
if [[ "${MINIMAL:-0}" == "1" ]]; then
  SNRS="20 5 0 -5 -8"
  # 每行: W1 LISTEN PERIOD HOLD NF_RISE_SH
  CONFIGS=(
    "8 8 16 32 7"    # 50% listen
  )
else
  SNRS="20 10 5 2 0 -5 -8"
  # 每行: W1 LISTEN PERIOD HOLD NF_RISE_SH
  CONFIGS=(
    "8 8 16 32 7"      # 50% listen
    "8 8 32 32 7"      # 25%
    "8 8 64 48 7"      # 12.5%
    "4 4 8 32 8"       # 50%
    "4 4 16 32 8"      # 25%
    "4 4 32 48 8"      # 12.5%
    "1 1 2 32 10"      # 50%
    "1 1 4 32 10"      # 25%
    "1 1 8 48 10"      # 12.5%
  )
fi

restore_rom() {
  "$PY" "$HERE/gen_signal_rom.py" >/dev/null 2>&1 || true
}
trap restore_rom EXIT INT TERM

printf 'snr\tw1\tlisten\tperiod\tphase\ton\tframes\tbase_det\tcand_lat\tts_det\tfalse_cand\tfalse_act_b\tfalse_act_ts\tt_wake_b\tt_result_b\tt_wake_ts\tt_result_ts\tcand_duty_pm\tres_b\tres_ts\n' > "$OUT"

for snr in $SNRS; do
  "$PY" "$HERE/gen_signal_rom.py" --snr "$snr" >/dev/null
  for cfg in "${CONFIGS[@]}"; do
    read -r w1 listen period hold nfshift <<< "$cfg"
    "$IVL" -g2012 -o "$HERE/tb_two_stage.out" \
      -DSNR_DB="$snr" -DW1="$w1" -DLISTEN="$listen" -DPERIOD="$period" \
      -DHOLD="$hold" -DNF_RISE_SH="$nfshift" \
      "$HERE/tb_two_stage.v" "$HERE/eng_stub.v" "$HERE/signal_rom.v" \
      "$ROOT/hw/gate/activity_detector.v" "$ROOT/hw/gate/gate_ctrl.v" \
      "$ROOT/hw/gate/wakeup_wu.v" "$ROOT/hw/gate/two_stage_detector.v"

    line="$("$VVP" "$HERE/tb_two_stage.out" | grep '^RESULT' | head -1 || true)"
    if [[ "$line" != RESULT\ snr=* ]]; then
      echo "WARN: no RESULT for snr=$snr cfg=$cfg: $line" >&2
      continue
    fi

    echo "$line" | awk '{
      for (i = 2; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
      print v["snr"]"\t"v["w1"]"\t"v["listen"]"\t"v["period"]"\t"v["phase"]"\t"v["on"]"\t"v["frames"]"\t"\
            v["base_det"]"\t"v["cand_lat"]"\t"v["ts_det"]"\t"\
            v["false_cand"]"\t"v["false_act_b"]"\t"v["false_act_ts"]"\t"\
            v["t_wake_b"]"\t"v["t_result_b"]"\t"v["t_wake_ts"]"\t"v["t_result_ts"]"\t"\
            v["cand_duty_pm"]"\t"v["res_b"]"\t"v["res_ts"]
    }' >> "$OUT"
  done
done

echo "done -> $OUT"
