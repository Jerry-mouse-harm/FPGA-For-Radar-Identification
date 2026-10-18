// wakeup_wu.v —— 二级唤醒（TOT WuRx，定时占空比的第一道筛选）
//
// 干什么用的：在 activity_detector **之前**再放一只"更省电、更粗"的眼睛。
//   它按"听 LISTEN 个有效样本 / 睡 PERIOD-LISTEN 个"的方式定时工作，
//   只在这段时间里做窗能量判决；报警（candidate=1）后才让第二级细检测器上电工作。
//
// 判决方式与 activity_detector **同一套**（方便和 LOG §7.2 的基线对比）：
//   · 窗内能量 Σ|din|（这里窗长 W1，比第二级的 W=16 短）
//   · 窗和 ≥ th_on → candidate=1，并保持 HOLD 个有效样本
//     （粗判**不做** th_off 提前回落：W1 窗很短，载波起伏会让单窗暂时掉到门限下，
//      提前回落会把第二级攒到一半的 W=16 窗清掉 → 低 SNR 相位敏感漏检。滞回交给第二级。）
//   · 噪声底自适应：泄漏最小值跟踪 nf，th_on = ON_NUM/ON_DEN · nf（默认 2×）
//
// 与常开检测器的区别：
//   1) 只在 listen 阶段累加，sleep 阶段不翻转（省动态功耗）；
//   2) 窗更短 → 触发更早，但单窗 SNR 增益小、假报警更多（由第二级确认）；
//   3) 触发后 candidate 保持 HOLD 个有效样本，给第二级攒够一个 W=16 窗。
//
// 注意：LISTEN 必须是 W1 的整数倍（保证 listen 段里都是完整窗，不被睡眠截断）。
module wakeup_wu #(
  parameter W1          = 8,      // 粗判窗长（有效样本数）
  parameter LISTEN      = 8,      // 每个周期听多少个有效样本（≥W1，且为 W1 的整数倍）
  parameter PERIOD      = 16,     // 听+睡的总周期（有效样本数，LISTEN≤PERIOD）
  parameter HOLD        = 32,     // candidate 触发后保持多少个有效样本
  parameter NF_RISE_SH  = 7,      // 噪声底慢升速率：nf += (nf>>SH)+1
  parameter ON_NUM      = 2,      // th_on  = ON_NUM/ON_DEN * nf
  parameter ON_DEN      = 1,
  parameter PHASE_INIT  = 0       // 上电时的听/睡相位（0..PERIOD-1，用于测相位对齐影响）
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire signed [7:0] din,
  input  wire              din_valid,
  output reg               candidate,   // 1 = 粗判到活动，放行第二级
  output wire [15:0]       nf_est       // 当前噪声底估计（W1 窗能量），给第二级复用
);

  localparam CNT_W  = (W1     <= 1) ? 1 : $clog2(W1);
  localparam PH_W   = (PERIOD <= 1) ? 1 : $clog2(PERIOD);
  localparam ACC_W  = $clog2(W1) + 8;
  localparam HOLD_W = (HOLD   <= 1) ? 1 : $clog2(HOLD + 1);

  reg [ACC_W-1:0]  acc;     // listen 窗内累加
  reg [CNT_W-1:0]  wcnt;    // 窗内样本计数
  reg [PH_W-1:0]   phase;   // 听/睡周期相位（按有效样本数走）
  reg [ACC_W-1:0]  nf;      // 噪声底估计（W1 窗能量）
  reg [HOLD_W-1:0] hold;    // candidate 保持计数

  // |din|：二补码取负 = 按位取反加 1（din=-128 也不溢出）
  wire [7:0]       e       = din[7] ? (~din + 8'd1) : din[7:0];
  wire [ACC_W-1:0] win_sum = acc + e;

  // 阈值（乘除都是常数，综合会化简成移位/加法）
  wire [ACC_W:0] th_on_ext = ({1'b0, nf} * ON_NUM) / ON_DEN;
  wire [ACC_W-1:0] th_on = th_on_ext[ACC_W] ? {ACC_W{1'b1}} : th_on_ext[ACC_W-1:0];

  // 泄漏最小值跟踪：底噪向下立即跟随，向上慢升（和 activity_detector 同款）
  wire [ACC_W:0] nf_rise = {1'b0, nf} + ({1'b0, nf} >> NF_RISE_SH) + 1'b1;

  assign nf_est = {{(16-ACC_W){1'b0}}, nf};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc       <= {ACC_W{1'b0}};
      wcnt      <= {CNT_W{1'b0}};
      phase     <= PHASE_INIT[PH_W-1:0];
      nf        <= {ACC_W{1'b1}};   // 初值取满：首窗不误触发，随即被第一个静息窗拉到底噪
      candidate <= 1'b0;
      hold      <= {HOLD_W{1'b0}};
    end
    else if (din_valid) begin
      // 1) 听/睡相位（只在有效样本上前进）
      if (phase == PERIOD - 1) phase <= {PH_W{1'b0}};
      else                     phase <= phase + 1'b1;

      // 2) candidate 保持计数：到期自动落（下面的触发/回落会覆盖它）
      if (hold != 0) begin
        hold <= hold - 1'b1;
        if (hold == 1) candidate <= 1'b0;
      end

      // 3) 只在 listen 段工作；sleep 段不累加、不翻转
      if (phase < LISTEN) begin
        if (wcnt == W1 - 1) begin
          // 窗边界判决（win_sum 含当前样本，和判分台同口径）
          if (win_sum >= th_on) begin
            candidate <= 1'b1;
            hold      <= HOLD;
          end
          // 注意：这里**不**做提前拉低 candidate。
          // 粗判窗只有 W1 点，脉冲载波起伏会让某个窗的能量暂时回落；
          // 若一回落就掉 candidate，第二级攒到一半的 W=16 窗会被清掉（低 SNR 相位敏感漏检的根因）。
          // candidate 只由 HOLD 到期清除，保证第二级至少拿到一段连续的 W 窗。

          // 底噪跟踪
          if (win_sum < nf) nf <= win_sum;
          else              nf <= nf_rise[ACC_W] ? {ACC_W{1'b1}} : nf_rise[ACC_W-1:0];

          acc  <= {ACC_W{1'b0}};
          wcnt <= {CNT_W{1'b0}};
        end
        else begin
          acc  <= win_sum;
          wcnt <= wcnt + 1'b1;
        end
      end
      else begin
        acc  <= {ACC_W{1'b0}};
        wcnt <= {CNT_W{1'b0}};
      end
    end
  end

endmodule
