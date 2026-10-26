// 读出层（FC2：32 → 5 类）+ argmax —— 识别引擎的最后一级
//
// 干什么用的：
//   FC1/LIF3 每个时间步输出 32 路脉冲。读出层不做 LIF，而是按训练端的
//   "脉冲率读出"约定，把 T 步脉冲计数后过一层线性分类器（src/models/snn_conv.py）：
//       count[r]  = Σ_t s3[t,r]                          // 0..T
//       logits[c] = Σ_r W2[c,r] · count[r] + B2[c] · T
//       class     = argmax_c logits[c]                   // 平局取最小索引
//   除以 T 只是全局缩放，不改变 argmax，所以硬件直接用计数。
//
// 架构：时间步外串行、神经元内串行
//   · 每来一拍 in_valid（FC1 的一个时间步），用 32 拍把 32 路脉冲扫一遍：
//     脉冲=1 就给 5 个类别累加器分别加上 W2[c,r]（5 个 20 位加法器，没有乘法器）。
//     32 拍 << 两个时间步之间的 513 拍，所以与 FC1 完全流水、不需要反压。
//   · 16 步全部累加完后，一个组合 argmax（5 路比较，`>` 保证平局取小索引），
//     再把 B2·T 加进去（T=16 → 左移 4 位）。
//
// 周期预算（T=16）：
//   每步 32 拍（+1 拍进 / 出状态）；16 步 = 16×33 ≈ 528 拍，最后 1 拍 argmax。
//   整帧 ≈ 530 拍 ≈ 20µs @27MHz。
//
// 权重 ROM：rtl/readout_wrom.v（自动生成）
//   addr_r = r（0..31）；dout_w[8*c +: 8] = W2[c][r]；dout_b = 5 个 16 bit 常量
//
// 端口：
//   clk/rst_n   : clk_eng / eng_rst_n（异步复位低有效）
//   frame_start : 来自 fc1_array，每帧开始 1 拍 → 清累加器/步计数
//   in_valid    : 来自 fc1_array 的 spk_valid（每帧 16 拍）
//   in_spike    : 来自 fc1_array 的 spk_vec（bit r = 神经元 r）
//   busy        : 一帧读出期间为 1（从第一个 in_valid 到 done）
//   done        : 出结果 1 拍（class/logits_out 同拍有效）
//   class       : 类别 0..4
//   logits_out  : 5 × 20 bit 有符号结果（含 B2·T），仅调试/判分用
module readout #(
  parameter integer NR = 32,   // FC1 神经元数
  parameter integer NC = 5,    // 类别数
  parameter integer T  = 16,   // 时间步数
  parameter integer LW = 20,   // logits 累加器位宽
  parameter integer TW = 16    // 偏置位宽
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire                frame_start,
  input  wire                in_valid,
  input  wire [NR-1:0]       in_spike,
  output reg                 busy,
  output reg                 done,
  output reg  [2:0]          cls,
  output reg  signed [NC*LW-1:0] logits_out
);

  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_ACC  = 2'd1;
  localparam [1:0] S_FIN  = 2'd2;
  localparam integer TSH  = $clog2(T);      // T=16 → 4（B2·T = 左移 4）

  reg [1:0]  state;
  reg [4:0]  r_q;                 // 当前神经元 0..NR-1
  reg [NR-1:0] sr_q;              // 脉冲移位寄存器
  reg [4:0]  step_cnt;            // 已处理的时间步数 0..T-1
  reg signed [LW-1:0] acc [0:NC-1];

  // ---------------- 权重 ROM（组合读）----------------
  wire [39:0]        w_row;       // NC × int8
  wire signed [79:0] b_const;     // NC × int16

  readout_wrom u_rom (
    .addr_r (r_q),
    .dout_w (w_row),
    .dout_b (b_const)
  );

  // ---------------- 组合 argmax ----------------
  integer ci;
  reg signed [LW-1:0] cand [0:NC-1];
  reg signed [LW-1:0] best;
  reg [2:0] best_c;

  always @(*) begin
    for (ci = 0; ci < NC; ci = ci + 1) begin
      // B2[c]·T：先符号扩展到 LW 再左移 TSH 位（T 是 2 的幂）
      cand[ci] = acc[ci] + ({{(LW-TW){b_const[TW*ci + TW - 1]}},
                             b_const[TW*ci +: TW]} <<< TSH);
    end
    best   = cand[0];
    best_c = 3'd0;
    for (ci = 1; ci < NC; ci = ci + 1) begin
      if (cand[ci] > best) begin       // > 而不是 >=：平局取小索引（与 PyTorch 一致）
        best   = cand[ci];
        best_c = ci;
      end
    end
  end

  // ---------------- 主状态机 ----------------
  integer j;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      done       <= 1'b0;
      cls        <= 3'd0;
      r_q        <= 5'd0;
      sr_q       <= {NR{1'b0}};
      step_cnt   <= 5'd0;
      logits_out <= {NC*LW{1'b0}};
      for (j = 0; j < NC; j = j + 1) acc[j] <= {LW{1'b0}};
    end else begin
      done <= 1'b0;                  // 默认单拍脉冲

      if (frame_start) begin
        // 新帧：清累加器和步计数（第一个 in_valid 还在 ~500 拍之后）
        step_cnt <= 5'd0;
        for (j = 0; j < NC; j = j + 1) acc[j] <= {LW{1'b0}};
      end

      case (state)
        // ------------------------------------------------------------
        S_IDLE: begin
          if (in_valid) begin
            sr_q  <= in_spike;
            r_q   <= 5'd0;
            busy  <= 1'b1;
            state <= S_ACC;
          end
        end

        // ------------------------------------------------------------
        // 32 拍扫完 32 路脉冲；每拍只有脉冲=1 才做 5 次条件加
        S_ACC: begin
          if (sr_q[0]) begin
            for (j = 0; j < NC; j = j + 1)
              acc[j] <= acc[j] + {{(LW-8){w_row[8*j + 7]}}, w_row[8*j +: 8]};
          end

          sr_q <= {1'b0, sr_q[NR-1:1]};

          if (r_q == NR-1) begin
            r_q  <= 5'd0;
            busy <= 1'b0;               // 本时间步的 32 路已扫完
            if (step_cnt == T-1) begin
              step_cnt <= 5'd0;
              state    <= S_FIN;
            end else begin
              step_cnt <= step_cnt + 1'b1;
              state    <= S_IDLE;
            end
          end else begin
            r_q <= r_q + 1'b1;
          end
        end

        // ------------------------------------------------------------
        // 出结果：acc 已含全部 T 步；cand 组合加 B2·T 后比大小
        S_FIN: begin
          for (j = 0; j < NC; j = j + 1)
            logits_out[j*LW +: LW] <= cand[j];
          cls    <= best_c;
          done   <= 1'b1;
          busy   <= 1'b0;
          state  <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
