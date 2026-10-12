// gate_ctrl —— 静息/激活两域门控 FSM（常开域 clk_sys 侧）
//
// 职责（严格按 hw/gate/INTERFACE.md §3/§4）：
//   · 产生门控时钟 clk_eng：静息时物理停跳（clk gate）
//   · 握手唤醒：时钟起振 → 复位引擎几拍 → 放复位 + eng_start 打 1 拍
//   · 2 级同步器收 eng_done / eng_busy（门控域 → 常开域）
//   · 记时延：t_wake（active↑ → clk_eng 首沿）、t_result（active↑ → eng_done 首沿）
//   · one-shot：出结果即关时钟，回静息（C1）
//
// ⚠ P3 未决（见 INTERFACE.md §6）：真实综合时把下面 "glitch-free ICG" 那两行
//    换成 Gowin 时钟使能原语（DCS / BUFGCE 类）。apycula 里有 BUFG/DCS/CLKDIV/PLL，
//    但 nextpnr-himbaechel 对"时钟使能单元"的支持还需上板核实；先用可移植写法。
//
// 域划分：本模块主体在 clk_sys（常开域）；eng_rst_n / eng_start 由 **clk_eng 域寄存器**发（§4.3）。

module gate_ctrl #(
  parameter CLK_SETTLE = 4,   // 时钟起振后等几拍（"时钟稳"再动引擎）
  parameter RST_CYCLES = 4    // 引擎复位保持几拍
)(
  input  wire       clk_sys,
  input  wire       rst_n,
  input  wire       active,          // 来自 activity_detector（常开域）
  // —— 引擎侧（门控域）——
  output wire       clk_eng,
  output reg        eng_rst_n,
  output reg        eng_start,
  input  wire       eng_busy,
  input  wire       eng_done,
  input  wire [2:0] eng_class,
  // —— 结果 / 时延（给顶层 / UART）——
  output reg        result_valid,
  output reg  [2:0] result_class,
  output reg [15:0] t_wake,
  output reg [15:0] t_result
);

  localparam S_IDLE   = 3'd0,
             S_SETTLE = 3'd1,
             S_RESET  = 3'd2,
             S_START  = 3'd3,
             S_RUN    = 3'd4;

  reg [2:0]  state;
  reg        clk_en;    // 时钟使能请求（常开域）
  reg [15:0] lat;       // 唤醒后经过的 clk_sys 拍数（时延计数）

  // ---------- glitch-free ICG：负沿采样使能，再与时钟相与 ----------
  // P3 换原语点：整段替换为 Gowin 时钟使能单元即可，clk_eng 语义不变。
  reg clk_en_q;
  always @(negedge clk_sys or negedge rst_n)
    if (!rst_n) clk_en_q <= 1'b0;
    else        clk_en_q <= clk_en;
  assign clk_eng = clk_sys & clk_en_q;

  // ---------- 2 级同步器：eng_done / eng_busy → 常开域 ----------
  reg [1:0] done_sync, busy_sync;
  always @(posedge clk_sys or negedge rst_n)
    if (!rst_n) begin done_sync <= 2'b0; busy_sync <= 2'b0; end
    else begin
      done_sync <= {done_sync[0], eng_done};
      busy_sync <= {busy_sync[0], eng_busy};
    end
  wire done_p = done_sync[1] & ~done_sync[0];   // 同步后的上升沿（1 拍）

  // ---------- clk_eng 域寄存器发跨缝信号（§4.3）----------
  // eng_rst_n / eng_start 的"下一值"由常开域 FSM 给出，经门控域寄存器打出去。
  reg eng_rst_n_c, eng_start_c;    // FSM 侧输出（clk_sys 域）
  always @(posedge clk_eng) begin  // 有初值；clk 停时保持
    eng_rst_n <= eng_rst_n_c;
    eng_start <= eng_start_c;
  end
  // 上电/复位初值：引擎先处于复位（时钟停着，安全）
  initial begin
    eng_rst_n = 1'b0;
    eng_start = 1'b0;
  end

  // ---------- clk_eng 首沿检测（用于 t_wake）----------
  // clk_en_q=1 在 clk_sys 正沿可见的那一拍，就是门控时钟的第一个有效沿。
  reg wake_seen;

  // ---------- 主 FSM（clk_sys）----------
  always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      clk_en       <= 1'b0;
      lat          <= 16'd0;
      result_valid <= 1'b0;
      result_class <= 3'd0;
      t_wake       <= 16'd0;
      t_result     <= 16'd0;
      eng_rst_n_c  <= 1'b0;   // 上电即扣复位
      eng_start_c  <= 1'b0;
      wake_seen    <= 1'b0;
    end
    else begin
      result_valid <= 1'b0;    // 默认非脉冲
      case (state)
        S_IDLE: begin
          clk_en      <= 1'b0;
          eng_rst_n_c <= 1'b0;   // 静息时引擎一直扣在复位里（始终低）
          eng_start_c <= 1'b0;
          lat         <= 16'd0;
          if (active) begin
            clk_en <= 1'b1;    // ① 时钟起振
            lat    <= 16'd1;   // 从 active 这一拍开始数
            state  <= S_SETTLE;
          end
        end

        S_SETTLE: begin        // ② 等时钟稳
          lat <= lat + 16'd1;
          if (!wake_seen && clk_en_q) begin  // 门控时钟第一个有效沿
            t_wake    <= lat;
            wake_seen <= 1'b1;
          end
          if (lat >= CLK_SETTLE) begin
            eng_rst_n_c <= 1'b0;             // 复位引擎（此前也已扣着）
            state       <= S_RESET;
          end
        end

        S_RESET: begin         // ③ 复位保持 RST_CYCLES 拍
          lat <= lat + 16'd1;
          if (lat >= CLK_SETTLE + RST_CYCLES) begin
            eng_rst_n_c <= 1'b1;                     // 放复位
            eng_start_c <= 1'b1;                     // 打 1 拍 start
            state       <= S_START;
          end
        end

        S_START: begin         // ④ start 脉冲这一拍
          lat <= lat + 16'd1;
          eng_start_c <= 1'b0;
          state       <= S_RUN;
        end

        S_RUN: begin           // ⑤ 等 eng_done
          lat <= lat + 16'd1;
          if (done_p) begin
            result_valid <= 1'b1;
            result_class <= eng_class;   // done 同步后 eng_class 已稳（同域同沿）
            t_result     <= lat + 16'd1;
            clk_en       <= 1'b0;   // one-shot 关时钟
            state        <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
