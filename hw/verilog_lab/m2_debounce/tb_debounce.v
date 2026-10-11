`timescale 1ns/1ns
// tb_debounce: 按键消抖判分台（自动 PASS/FAIL）
//
// 只考三条"性质"，不卡死具体拍数（实现比规格晚/早一两拍也算对）：
//   ① 单拍脉冲抖动（每拍都翻）连抖 20 拍 → key_out 不得变
//   ② 稳定保持不变超过 CNT_MAX 拍 → key_out 必须跟上（给足裕量等待）
//   ③ 周期性抖动（每 2 拍翻一次）持续 40 拍 → key_out 仍不得变
// 判据 ①③ 的含义：抖动的特点是"稳定时间短于消抖窗口"，无论如何都传不过去。
module tb_debounce;
  localparam CNT_MAX = 5;
  localparam WAIT    = CNT_MAX*3 + 10;      // 等待 key_out 跟上的裕量

  reg clk = 0;
  reg rst_n = 0;
  reg key_in = 0;
  wire key_out;
  integer err = 0;
  integer i;

  key_debounce #(.CNT_MAX(CNT_MAX)) u_dut (
    .clk(clk), .rst_n(rst_n), .key_in(key_in), .key_out(key_out)
  );

  always #5 clk = ~clk;

  task set_key(input v);
    begin @(negedge clk); key_in = v; end
  endtask

  task check(input e, input [8*24-1:0] msg);
    begin
      if (key_out !== e) begin
        $display("FAIL %0s @%0t: key_out=%0b (expect %0b)", msg, $time, key_out, e);
        err = err + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_debounce.vcd");
    $dumpvars(0, tb_debounce);

    rst_n = 0;
    #20 rst_n = 1;
    #1; check(1'b0, "reset");

    // ---- ① 最短抖动: 每拍翻一次, 连续 20 拍 ----
    for (i = 0; i < 20; i = i + 1) begin
      set_key(1'b1); check(1'b0, "jitter-1cyc-hi");
      set_key(1'b0); check(1'b0, "jitter-1cyc-lo");
    end

    // ---- ② 稳定置 1, 等够了就该跟上 ----
    set_key(1'b1);
    repeat (WAIT) @(posedge clk);
    #1; check(1'b1, "stable-1");

    // ---- ③ 周期抖动: 每 2 拍翻一次, 持续 40 拍 ----
    for (i = 0; i < 10; i = i + 1) begin
      set_key(1'b0); repeat (2) @(posedge clk);
      set_key(1'b1); repeat (2) @(posedge clk);
    end
    #1; check(1'b1, "jitter-2cyc");

    // ---- 稳定置 0, 等够了也该跟上 ----
    set_key(1'b0);
    repeat (WAIT) @(posedge clk);
    #1; check(1'b0, "stable-0");

    if (err == 0) $display(">>> tb_debounce PASS (毛刺全滤掉, 稳定电平能跟上)");
    else          $display(">>> tb_debounce FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #8000 $display(">>> tb_debounce TIMEOUT"); $finish; end
endmodule
