`timescale 1ns/1ns
// tb_counter: 模 MOD 计数器判分台（自动 PASS/FAIL）
// 测试内容: 使能计数递增 / 模 MOD 回绕产生 done 脉冲 / en=0 冻结 / 异步复位
module tb_counter;
  reg clk = 0;
  reg rst_n = 0;
  reg en = 0;
  wire [3:0] cnt;
  wire done;
  integer err = 0;

  counter #(.WIDTH(4), .MOD(10))
    u_dut (.clk(clk), .rst_n(rst_n), .en(en), .cnt(cnt), .done(done));

  always #5 clk = ~clk;

  // 在时钟沿后 #1 采样，比期待值
  task check(input [3:0] ec, input ed, input integer step);
    begin
      if (cnt !== ec || done !== ed) begin
        $display("FAIL step %0d @%0t: cnt=%0d (expect %0d)  done=%0b (expect %0b)",
                 step, $time, cnt, ec, done, ed);
        err = err + 1;
      end
    end
  endtask

  integer i;
  initial begin
    $dumpfile("tb_counter.vcd");
    $dumpvars(0, tb_counter);

    // 复位 0~20ns，释放后 en=1
    rst_n = 0; en = 0;
    #20 rst_n = 1;
    #1  en = 1;                 // 第一个计数沿 = 第 1 个 @(posedge)

    // 连续数 30 个沿：cnt=i%10，done 在第 10/20/30 个沿为 1
    for (i = 1; i <= 30; i = i + 1) begin
      @(posedge clk); #1;
      check(i % 10, (i % 10 == 0) ? 1'b1 : 1'b0, i);
    end

    // --- en=0 冻结 ---
    en = 0;
    repeat (3) @(posedge clk); #1;
    check(0, 1'b0, -1);                 // 30%10=0

    // --- 异步复位 ---
    rst_n = 0;                          // 任意时刻拉低都应立刻清 0
    repeat (3) @(posedge clk); #1;      // 复位期间多个沿仍保持 0
    check(0, 1'b0, -2);
    rst_n = 1;                          // 释放（en=0，不应计数）
    @(posedge clk); #1;
    check(0, 1'b0, -3);

    // 释放后重新使能
    en = 1;
    @(posedge clk); #1; check(1, 1'b0, -4);
    @(posedge clk); #1; check(2, 1'b0, -5);

    if (err == 0) $display(">>> tb_counter PASS");
    else          $display(">>> tb_counter FAIL (err=%0d)", err);
    $finish;
  end

  // 兜底超时：防止模块写坏导致死等
  initial begin #2000 $display(">>> tb_counter TIMEOUT"); $finish; end
endmodule
