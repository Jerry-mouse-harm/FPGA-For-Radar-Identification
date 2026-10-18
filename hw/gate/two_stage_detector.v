// two_stage_detector.v —— 两级唤醒检测（TOT WuRx → 细检测器）
//
// 结构：
//   din ──> wakeup_wu（短窗 W1 + 听/睡占空比，常开、便宜）
//              │ candidate
//              ▼
//        细检测器（W=16，只在 candidate=1 时累加；判决仍是 Σ|din| + 双阈值滞回）
//              │ active
//              ▼
//           gate_ctrl
//
// 为什么细检测器不自带噪声底跟踪：
//   它静息时被关掉，重新上电时没有历史窗可估底噪（原 activity_detector 的 nf
//   从满值开始，要看到静息窗才会降下来）。这里直接复用 WuRx 的 nf，按窗长比例
//   折算成 W=16 的底噪：th_on = 2·nf1·(W/W1)，th_off = 1.5·nf1·(W/W1)。
//   判决门限与 activity_detector 的 ADAPT=1 同口径，只是 nf 的来源不同。
//
// 参数约束：W 必须是 W1 的整数倍；LISTEN 必须是 W1 的整数倍；HOLD ≥ W。
module two_stage_detector #(
  parameter W           = 16,
  parameter W1          = 8,
  parameter LISTEN      = 8,
  parameter PERIOD      = 16,
  parameter HOLD        = 32,
  parameter NF_RISE_SH  = 7,
  parameter PHASE_INIT  = 0,
  parameter ON_NUM      = 2,   // 粗判 th_on = ON_NUM/ON_DEN * nf1
  parameter ON_DEN      = 1
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire signed [7:0] din,
  input  wire              din_valid,
  output wire              candidate,   // WuRx 粗判（也引出来，方便测量）
  output reg               active,      // 细检测确认后的活动（喂 gate_ctrl）
  output wire [15:0]       nf_est       // WuRx 噪声底（调试/测量用）
);

  localparam CNT_W = (W <= 1) ? 1 : $clog2(W);
  localparam ACC_W = $clog2(W) + 8;
  localparam SCALE = W / W1;            // 底噪从 W1 窗折算到 W 窗

  // ---------- 第一级：TOT WuRx ----------
  wakeup_wu #(
    .W1(W1), .LISTEN(LISTEN), .PERIOD(PERIOD), .HOLD(HOLD),
    .NF_RISE_SH(NF_RISE_SH), .PHASE_INIT(PHASE_INIT),
    .ON_NUM(ON_NUM), .ON_DEN(ON_DEN)
  ) u_wu (
    .clk(clk), .rst_n(rst_n), .din(din), .din_valid(din_valid),
    .candidate(candidate), .nf_est(nf_est)
  );

  // ---------- 第二级：W 窗细检测（candidate 门控累加）----------
  reg [ACC_W-1:0] acc;
  reg [CNT_W-1:0] s_cnt;

  wire [7:0]       e       = din[7] ? (~din + 8'd1) : din[7:0];
  wire [ACC_W-1:0] win_sum = acc + e;
  wire [31:0]      win_sum32 = {{(32-ACC_W){1'b0}}, win_sum};

  // 用 WuRx 的 nf1 折算阈值（nf1 是 W1 窗能量）
  wire [31:0] th_on_f32  = nf_est * (2 * SCALE);
  wire [31:0] th_off_f32 = (nf_est * (3 * SCALE)) >> 1;   // 1.5 * nf1 * SCALE

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc    <= {ACC_W{1'b0}};
      s_cnt  <= {CNT_W{1'b0}};
      active <= 1'b0;
    end
    else if (!candidate) begin
      // 第一级说静息：第二级断电，清状态（再唤醒时重新攒窗）
      acc    <= {ACC_W{1'b0}};
      s_cnt  <= {CNT_W{1'b0}};
      active <= 1'b0;
    end
    else if (din_valid) begin
      if (s_cnt == W - 1) begin          // 窗边界
        if      (win_sum32 >= th_on_f32)  active <= 1'b1;
        else if (win_sum32 <= th_off_f32) active <= 1'b0;
        // 中间带：保持（滞回）
        acc   <= {ACC_W{1'b0}};
        s_cnt <= {CNT_W{1'b0}};
      end
      else begin
        acc   <= win_sum;
        s_cnt <= s_cnt + 1'b1;
      end
    end
  end

endmodule
