`timescale 1ns/1ns
// tb_edge: 边沿检测判分台（自动 PASS/FAIL）
// 约定：sig_in 在时钟沿之间变化 → 下一个 posedge 锁存新值，
//       同时 rise/fall 拉高 1 拍（比边沿晚一个时钟）。
module tb_edge;
  reg clk = 0;
  reg rst_n = 0;
  reg sig_in = 0;
  wire rise, fall;
  integer err = 0;

  edge_det u_dut (.clk(clk), .rst_n(rst_n), .sig_in(sig_in), .rise(rise), .fall(fall));

  always #5 clk = ~clk;

  task check(input e_rise, input e_fall, input [8*24-1:0] msg);
    begin
      if (rise !== e_rise || fall !== e_fall) begin
        $display("FAIL %0s @%0t: rise=%0b(exp %0b) fall=%0b(exp %0b)",
                 msg, $time, rise, e_rise, fall, e_fall);
        err = err + 1;
      end
    end
  endtask

  integer i;
  initial begin
    $dumpfile("tb_edge.vcd");
    $dumpvars(0, tb_edge);

    rst_n = 0;
    #20 rst_n = 1;

    // 空闲几个周期：应无任何脉冲
    repeat (3) begin @(posedge clk); #1; check(0, 0, "idle"); end

    // --- 上升沿：让 sig_in 在沿间变高，下一个 posedge 应 rise=1 ---
    sig_in = 1;                       // (当前处于两个时钟沿之间)
    @(posedge clk); #1; check(1, 0, "rise1");
    @(posedge clk); #1; check(0, 0, "rise-hold1");
    @(posedge clk); #1; check(0, 0, "rise-hold2");

    // --- 保持高电平几个周期，不应再出脉冲 ---
    repeat (2) begin @(posedge clk); #1; check(0, 0, "high-idle"); end

    // --- 下降沿：sig_in 变低，下一个 posedge 应 fall=1 ---
    sig_in = 0;
    @(posedge clk); #1; check(0, 1, "fall1");
    @(posedge clk); #1; check(0, 0, "fall-hold1");

    // --- 再来一次上升沿，确认 rise 能再次触发 ---
    sig_in = 1;
    @(posedge clk); #1; check(1, 0, "rise2");
    @(posedge clk); #1; check(0, 0, "rise2-hold");

    if (err == 0) $display(">>> tb_edge PASS");
    else          $display(">>> tb_edge FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #2000 $display(">>> tb_edge TIMEOUT"); $finish; end
endmodule
