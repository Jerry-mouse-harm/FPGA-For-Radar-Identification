`timescale 1ns/1ns
// tb_gate_ctrl: 门控 FSM 判分台（含 stub 引擎，自动 PASS/FAIL）
//
// 验的东西（INTERFACE.md §4）：
//   1) 静息：clk_eng 必须停跳（0 个沿），result_valid=0
//   2) 唤醒：active↑ → 时钟起振 → 复位 → start → 跑完 → result_valid 脉冲 + result_class
//   3) one-shot：出结果后时钟必须再次停跳
//   4) 时延口径：t_wake（active↑→clk_eng 首沿）、t_result（active↑→done）都非 0 且 t_result > t_wake
//   5) 二次唤醒：能再来一遍（不是一次性状态机）
//
// stub 引擎：收到 eng_start 后跑 T 步，拉 eng_done 1 拍并给一个固定类别。
module tb_gate_ctrl;
  localparam T  = 16;
  localparam CLK_SETTLE = 4;
  localparam RST_CYCLES = 4;

  reg  clk_sys = 0, rst_n = 0, active = 0;
  wire clk_eng;
  wire eng_rst_n, eng_start, eng_busy, eng_done;
  wire [2:0] eng_class;
  wire result_valid;
  wire [2:0] result_class;
  wire [15:0] t_wake, t_result;

  integer err = 0;
  integer eng_edges = 0;
  integer guard;

  gate_ctrl #(.CLK_SETTLE(CLK_SETTLE), .RST_CYCLES(RST_CYCLES)) dut (
    .clk_sys(clk_sys), .rst_n(rst_n), .active(active),
    .clk_eng(clk_eng), .eng_rst_n(eng_rst_n), .eng_start(eng_start),
    .eng_busy(eng_busy), .eng_done(eng_done), .eng_class(eng_class),
    .result_valid(result_valid), .result_class(result_class),
    .t_wake(t_wake), .t_result(t_result)
  );

  // ---- stub 引擎（门控域）：start → 跑 T 步 → done 1 拍 ----
  eng_stub #(.T(T)) u_eng (
    .clk(clk_eng), .rst_n(eng_rst_n), .start(eng_start),
    .busy(eng_busy), .done(eng_done), .cls(eng_class)
  );

  always #5 clk_sys = ~clk_sys;
  always @(posedge clk_eng) eng_edges = eng_edges + 1;

  // 一次唤醒：拉 active，等 result_valid，回读结果 + 时延
  task wake_and_check(input [2:0] exp_class, input integer tag);
    begin
      eng_edges = 0;
      @(negedge clk_sys); active = 1'b1;
      guard = 0;
      while (result_valid !== 1'b1 && guard < 500) begin
        @(posedge clk_sys); #1; guard = guard + 1;
      end
      if (result_valid !== 1'b1) begin
        $display("FAIL wake#%0d: result_valid 未拉高 (timeout)", tag);
        err = err + 1;
      end
      else begin
        if (result_class !== exp_class) begin
          $display("FAIL wake#%0d: result_class=%0d (expect %0d)", tag, result_class, exp_class);
          err = err + 1;
        end
        if (t_wake == 0 || t_result == 0 || t_result <= t_wake) begin
          $display("FAIL wake#%0d: 时延口径异常 t_wake=%0d t_result=%0d", tag, t_wake, t_result);
          err = err + 1;
        end
        else begin
          $display("INFO wake#%0d: t_wake=%0d t_result=%0d clk_sys 拍 (引擎 T=%0d)", tag, t_wake, t_result, T);
        end
      end
      @(negedge clk_sys); active = 1'b0;
    end
  endtask

  initial begin
    $dumpfile("tb_gate_ctrl.vcd");
    $dumpvars(0, tb_gate_ctrl);

    // 复位
    rst_n = 0;
    repeat (4) @(posedge clk_sys); #1;
    rst_n = 1;

    // ---- 1) 静息：时钟必须停 ----
    repeat (20) @(posedge clk_sys); #1;
    eng_edges = 0;
    repeat (20) @(posedge clk_sys); #1;
    if (eng_edges !== 0) begin
      $display("FAIL idle: clk_eng 在静息时跳了 %0d 个沿 (expect 0)", eng_edges);
      err = err + 1;
    end
    if (result_valid !== 1'b0) begin
      $display("FAIL idle: result_valid=%0b (expect 0)", result_valid); err = err + 1;
    end

    // ---- 2/4) 第一次唤醒 ----
    wake_and_check(3'd3, 1);

    // ---- 3) one-shot：出结果后时钟又停了 ----
    eng_edges = 0;
    repeat (20) @(posedge clk_sys); #1;
    if (eng_edges !== 0) begin
      $display("FAIL one-shot: 出结果后 clk_eng 还在跳 (%0d 沿, expect 0)", eng_edges);
      err = err + 1;
    end

    // ---- 5) 二次唤醒 ----
    wake_and_check(3'd3, 2);

    if (err == 0)
      $display(">>> tb_gate_ctrl PASS (静息停钟 + 唤醒握手 + one-shot + 二次唤醒)");
    else
      $display(">>> tb_gate_ctrl FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #200000 $display(">>> tb_gate_ctrl TIMEOUT"); $finish; end
endmodule

// ---- stub 引擎：门控域，start 后跑 T 步出 done ----
module eng_stub #(parameter T = 16)(
  input  wire       clk,
  input  wire       rst_n,
  input  wire       start,
  output reg        busy,
  output reg        done,
  output reg  [2:0] cls
);
  reg [4:0] step;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      step <= 5'd0; busy <= 1'b0; done <= 1'b0; cls <= 3'd0;
    end
    else begin
      done <= 1'b0;
      if (start) begin
        step <= 5'd0; busy <= 1'b1;
      end
      else if (busy) begin
        if (step == T - 1) begin
          busy <= 1'b0;
          done <= 1'b1;
          cls  <= 3'd3;      // 假装识别成类别 3
        end
        else step <= step + 1'b1;
      end
    end
endmodule
