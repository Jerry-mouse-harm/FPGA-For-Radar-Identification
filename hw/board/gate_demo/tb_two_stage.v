`timescale 1ns/1ns
// tb_two_stage —— 两级唤醒 A/B 测量台（记录用，非判分）
//
// 同一路 din 并行跑两条链：
//   基线：activity_detector (W=16, ADAPT=1) → gate_ctrl → eng_stub
//   两级：wakeup_wu (短窗+定时占空比) → 细检测 (W=16) → gate_ctrl → eng_stub
//
// 输出（一行 RESULT，供脚本扫 SNR × 占空比）：
//   · base_det / ts_det / cand_lat：真实脉冲起始(样本 26) → 各自拉高，单位=样本。
//     口径与 LOG §7.2 一致：判决窗末样本 sidx 的"下一个样本"才算延迟，即 sidx-26+1。
//   · false_cand / false_act_*：静息区误报次数（整段累计，脚本按帧数平均）
//   · t_wake_b / t_result_b / t_wake_ts / t_result_ts：gate_ctrl 时延，单位=clk_sys 拍
//   · cand_duty_pm：candidate 高电平时间占比（千分比）= 第二级工作时间占比
//
// 采样时刻：DUT 在 posedge 吃样本，输出在 NBA 后更新 → 本台统一在 negedge 读，
// 用 last_sidx（最近一个有效样本的地址）归属判决样本。
//
// 宏：W1 / LISTEN / PERIOD / HOLD / NF_RISE_SH / PHASE_OFFSET / ON_NUM / ON_DEN /
//     SNR_DB / FRAMES
`ifndef W1
`define W1 8
`endif
`ifndef LISTEN
`define LISTEN 8
`endif
`ifndef PERIOD
`define PERIOD 16
`endif
`ifndef HOLD
`define HOLD 32
`endif
`ifndef NF_RISE_SH
`define NF_RISE_SH 7
`endif
`ifndef PHASE_OFFSET
`define PHASE_OFFSET 0
`endif
`ifndef ON_NUM
`define ON_NUM 2
`endif
`ifndef ON_DEN
`define ON_DEN 1
`endif
`ifndef SNR_DB
`define SNR_DB 20
`endif
`ifndef FRAMES
`define FRAMES 20
`endif

module tb_two_stage;
  localparam SMP_DIV = 3;                 // 每样本 2^3=8 拍（仿真加速）
  localparam WT      = 16;                // 细检测窗长
  localparam P0      = 26;                // 脉冲起始样本（gen_signal_rom.py）

  reg  clk = 0;
  always #5 clk = ~clk;

  // ---------- 上电复位 + 样本播放（与 gate_demo 同款）----------
  reg [7:0] por = 8'd0;
  wire      rst_n = &por;
  always @(posedge clk) if (!rst_n) por <= por + 1'b1;

  reg [23:0] smp_cnt = 24'd0;
  always @(posedge clk)
    if (!rst_n) smp_cnt <= 24'd0;
    else        smp_cnt <= smp_cnt + 1'b1;
  wire din_valid = (smp_cnt[SMP_DIV-1:0] == 0);

  reg [6:0] addr = 7'd0;
  always @(posedge clk)
    if (!rst_n)         addr <= 7'd0;
    else if (din_valid) addr <= (addr == 7'd127) ? 7'd0 : addr + 7'd1;

  wire signed [7:0] din;
  wire              truth;
  signal_rom u_rom (.addr(addr), .din(din), .truth(truth));

  // ---------- 基线链 ----------
  wire active_b;
  activity_detector #(.W(WT), .ADAPT(1)) u_ad_b (
    .clk(clk), .rst_n(rst_n), .din(din), .din_valid(din_valid), .active(active_b)
  );
  wire        clk_eng_b, eng_rst_n_b, eng_start_b, eng_busy_b, eng_done_b;
  wire [2:0]  eng_class_b;
  wire        result_valid_b;
  wire [2:0]  result_class_b;
  wire [15:0] t_wake_b, t_result_b;
  gate_ctrl u_gate_b (
    .clk_sys(clk), .rst_n(rst_n), .active(active_b),
    .clk_eng(clk_eng_b), .eng_rst_n(eng_rst_n_b), .eng_start(eng_start_b),
    .eng_busy(eng_busy_b), .eng_done(eng_done_b), .eng_class(eng_class_b),
    .result_valid(result_valid_b), .result_class(result_class_b),
    .t_wake(t_wake_b), .t_result(t_result_b)
  );
  eng_stub u_eng_b (
    .clk(clk_eng_b), .rst_n(eng_rst_n_b), .start(eng_start_b),
    .busy(eng_busy_b), .done(eng_done_b), .cls(eng_class_b)
  );

  // ---------- 两级链 ----------
  wire candidate_ts, active_ts;
  wire [15:0] nf_ts;
  two_stage_detector #(
    .W(WT), .W1(`W1), .LISTEN(`LISTEN), .PERIOD(`PERIOD),
    .HOLD(`HOLD), .NF_RISE_SH(`NF_RISE_SH), .PHASE_INIT(`PHASE_OFFSET),
    .ON_NUM(`ON_NUM), .ON_DEN(`ON_DEN)
  ) u_ts (
    .clk(clk), .rst_n(rst_n), .din(din), .din_valid(din_valid),
    .candidate(candidate_ts), .active(active_ts), .nf_est(nf_ts)
  );
  wire        clk_eng_ts, eng_rst_n_ts, eng_start_ts, eng_busy_ts, eng_done_ts;
  wire [2:0]  eng_class_ts;
  wire        result_valid_ts;
  wire [2:0]  result_class_ts;
  wire [15:0] t_wake_ts, t_result_ts;
  gate_ctrl u_gate_ts (
    .clk_sys(clk), .rst_n(rst_n), .active(active_ts),
    .clk_eng(clk_eng_ts), .eng_rst_n(eng_rst_n_ts), .eng_start(eng_start_ts),
    .eng_busy(eng_busy_ts), .eng_done(eng_done_ts), .eng_class(eng_class_ts),
    .result_valid(result_valid_ts), .result_class(result_class_ts),
    .t_wake(t_wake_ts), .t_result(t_result_ts)
  );
  eng_stub u_eng_ts (
    .clk(clk_eng_ts), .rst_n(eng_rst_n_ts), .start(eng_start_ts),
    .busy(eng_busy_ts), .done(eng_done_ts), .cls(eng_class_ts)
  );

  // ---------- 测量 ----------
  integer last_sidx = -1;
  reg     last_truth = 1'b0;
  reg     wrap_flag = 1'b0;

  always @(posedge clk) begin
    if (rst_n && din_valid) begin
      last_sidx  <= addr;
      last_truth <= truth;
    end
    wrap_flag <= rst_n && din_valid && (addr == 7'd127);
  end

  integer frame = 0;
  integer total_clks = 0;
  integer cand_on_clks = 0;

  integer false_cand = 0, false_act_b = 0, false_act_ts = 0;
  integer cand_lat_sum = 0, b_lat_sum = 0, ts_lat_sum = 0;
  integer cand_lat_n = 0, b_lat_n = 0, ts_lat_n = 0;
  reg     got_cand_f = 0, got_b_f = 0, got_ts_f = 0;

  integer res_b = 0, res_ts = 0;
  reg [15:0] tw_b_l = 0, tr_b_l = 0, tw_ts_l = 0, tr_ts_l = 0;

  reg prev_cand = 0, prev_b = 0, prev_ts = 0;

  always @(negedge clk) begin
    if (rst_n) begin
      total_clks = total_clks + 1;
      if (candidate_ts) cand_on_clks = cand_on_clks + 1;

      // ---- candidate 上升沿 ----
      if (candidate_ts && !prev_cand) begin
        if (last_sidx >= P0 && last_sidx <= 63 + `W1 - 1) begin
          if (!got_cand_f) begin
            cand_lat_sum = cand_lat_sum + (last_sidx - P0 + 1);
            cand_lat_n   = cand_lat_n + 1;
            got_cand_f   = 1'b1;
          end
        end
        else if (last_sidx < P0 || last_sidx >= 63 + `W1) begin
          false_cand = false_cand + 1;
        end
      end
      prev_cand = candidate_ts;

      // ---- 基线 active 上升沿 ----
      if (active_b && !prev_b) begin
        if (last_sidx >= P0 && last_sidx <= 63 + WT - 1) begin
          if (!got_b_f) begin
            b_lat_sum = b_lat_sum + (last_sidx - P0 + 1);
            b_lat_n   = b_lat_n + 1;
            got_b_f   = 1'b1;
          end
        end
        else if (last_sidx < P0 || last_sidx >= 63 + WT) begin
          false_act_b = false_act_b + 1;
        end
      end
      prev_b = active_b;

      // ---- 两级 active 上升沿 ----
      if (active_ts && !prev_ts) begin
        if (last_sidx >= P0 && last_sidx <= 63 + WT - 1) begin
          if (!got_ts_f) begin
            ts_lat_sum = ts_lat_sum + (last_sidx - P0 + 1);
            ts_lat_n   = ts_lat_n + 1;
            got_ts_f   = 1'b1;
          end
        end
        else if (last_sidx < P0 || last_sidx >= 63 + WT) begin
          false_act_ts = false_act_ts + 1;
        end
      end
      prev_ts = active_ts;

      // ---- 唤醒时延（取每帧第一次结果的 t_wake/t_result）----
      if (result_valid_b) begin
        tw_b_l = t_wake_b; tr_b_l = t_result_b; res_b = res_b + 1;
      end
      if (result_valid_ts) begin
        tw_ts_l = t_wake_ts; tr_ts_l = t_result_ts; res_ts = res_ts + 1;
      end

      // ---- 帧边界 ----
      if (wrap_flag) begin
        frame = frame + 1;
        got_cand_f = 1'b0; got_b_f = 1'b0; got_ts_f = 1'b0;
        if (frame >= `FRAMES) begin
          $display("RESULT snr=%0d w1=%0d listen=%0d period=%0d phase=%0d on=%0d/%0d frames=%0d base_det=%0d cand_lat=%0d ts_det=%0d false_cand=%0d false_act_b=%0d false_act_ts=%0d t_wake_b=%0d t_result_b=%0d t_wake_ts=%0d t_result_ts=%0d cand_duty_pm=%0d res_b=%0d res_ts=%0d",
                   `SNR_DB, `W1, `LISTEN, `PERIOD, `PHASE_OFFSET, `ON_NUM, `ON_DEN, frame,
                   (b_lat_n   ? (b_lat_sum + b_lat_n/2)   / b_lat_n   : -1),
                   (cand_lat_n? (cand_lat_sum + cand_lat_n/2)/cand_lat_n: -1),
                   (ts_lat_n  ? (ts_lat_sum + ts_lat_n/2) / ts_lat_n  : -1),
                   false_cand, false_act_b, false_act_ts,
                   tw_b_l, tr_b_l, tw_ts_l, tr_ts_l,
                   (total_clks ? (cand_on_clks * 1000) / total_clks : 0),
                   res_b, res_ts);
          $finish;
        end
      end
    end
  end

  initial begin
    #1000000;
    $display("RESULT TIMEOUT snr=%0d w1=%0d listen=%0d period=%0d frame=%0d",
             `SNR_DB, `W1, `LISTEN, `PERIOD, frame);
    $finish;
  end
endmodule
