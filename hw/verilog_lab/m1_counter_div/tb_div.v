`timescale 1ns/1ns
// tb_div: 任意 N 分频判分台（自动 PASS/FAIL）
// 分别例化 N=4(偶)、N=5(奇)，实测每个输出周期的 period 与高电平时长
//   期望: N=4 -> period=40ns high=20ns
//         N=5 -> period=50ns high=25ns
// 注意：两个测量 initial 并发运行，变量必须各自块内私有。
module tb_div;
  reg clk = 0;
  reg rst_n = 0;
  reg go = 0;
  wire out4, out5;
  integer err = 0;
  integer done_cnt = 0;   // 两个测量块都完成后，再由汇总块判 PASS/FAIL

  div_N #(.N(4)) u4 (.clk(clk), .rst_n(rst_n), .out_clk(out4));
  div_N #(.N(5)) u5 (.clk(clk), .rst_n(rst_n), .out_clk(out5));

  always #5 clk = ~clk;

  initial begin
    $dumpfile("tb_div.vcd");
    $dumpvars(0, tb_div);
    rst_n = 0;
    #20 rst_n = 1;
    #10 go = 1;
  end

  // ---- 量 N=4（变量全私有）----
  initial begin
    time tr, tf, tr2;
    integer cyc, per, high;
    integer local_err;
    local_err = 0;
    wait(go);
    wait(out4 == 1'b0);                // 等信号已知
    @(posedge out4); tr = $time;       // 记录第一次上升
    for (cyc = 0; cyc < 6; cyc = cyc + 1) begin
      @(negedge out4); tf = $time;
      @(posedge out4); tr2 = $time;
      per  = tr2 - tr;
      high = tf - tr;
      $display("  N=4 cyc%0d: period=%0t high=%0t low=%0t", cyc, per, high, tr2 - tf);
      if (per != 40 || high != 20) local_err = local_err + 1;
      tr = tr2;
    end
    err = err + local_err;
    done_cnt = done_cnt + 1;
  end

  // ---- 量 N=5（变量全私有）----
  initial begin
    time tr, tf, tr2;
    integer cyc, per, high;
    integer local_err;
    local_err = 0;
    wait(go);
    wait(out5 == 1'b0);
    @(posedge out5); tr = $time;
    for (cyc = 0; cyc < 6; cyc = cyc + 1) begin
      @(negedge out5); tf = $time;
      @(posedge out5); tr2 = $time;
      per  = tr2 - tr;
      high = tf - tr;
      $display("  N=5 cyc%0d: period=%0t high=%0t low=%0t", cyc, per, high, tr2 - tf);
      if (per != 50 || high != 25) local_err = local_err + 1;
      tr = tr2;
    end
    err = err + local_err;
    done_cnt = done_cnt + 1;
  end

  // ---- 汇总：两个块都量完再判 ----
  initial begin
    wait(done_cnt == 2);
    #1;
    if (err == 0) $display(">>> tb_div 全部 PASS: N=4(偶)40/20  N=5(奇)50/25");
    else          $display(">>> tb_div FAIL (err=%0d)", err);
    $finish;
  end

  // 兜底超时（模块写坏 / 死等时触发）
  initial begin #3000 $display(">>> tb_div TIMEOUT（输出没翻转？）"); $finish; end
endmodule
