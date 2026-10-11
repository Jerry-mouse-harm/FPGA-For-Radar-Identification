`timescale 1ns/1ns
// tb_shift: 串入并出移位寄存器判分台（自动 PASS/FAIL）
// 喂法：负沿摆好 din/en，正沿后 #1 采样 q（和后级寄存器看到的一致）
//   考 4 件事：复位清零 / 收一半的值 / 收满 WIDTH 位的值 / en=0 保持 / 老数据移出
module tb_shift;
  localparam WIDTH = 8;
  localparam [WIDTH-1:0] PAT = 8'b1011_0010;   // 按 b7→b0 的顺序逐位喂入

  reg clk = 0;
  reg rst_n = 0;
  reg en = 0;
  reg din = 0;
  wire [WIDTH-1:0] q;
  integer err = 0;
  integer i;

  shift_reg #(.WIDTH(WIDTH)) u_dut (.clk(clk), .rst_n(rst_n), .en(en), .din(din), .q(q));

  always #5 clk = ~clk;

  task check(input [WIDTH-1:0] e_q, input [8*24-1:0] msg);
    begin
      if (q !== e_q) begin
        $display("FAIL %0s @%0t: q=%b (expect %b)", msg, $time, q, e_q);
        err = err + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_shift.vcd");
    $dumpvars(0, tb_shift);

    rst_n = 0;
    #20 rst_n = 1;

    // --- 复位后应全 0 ---
    @(negedge clk); #1; check(8'h00, "reset");

    // --- 逐位喂入 PAT（高位先喂）---
    for (i = 0; i < WIDTH; i = i + 1) begin
      @(negedge clk); en = 1; din = PAT[WIDTH-1-i];
      @(posedge clk); #1;
      if (i == 3) check(8'h0B, "mid-4bit");    // 只收了 4 位: 1011 停在低 4 位
    end
    check(PAT, "full-8bit");                   // 收满 8 位

    // --- en=0 时保持不动（din 故意扰动）---
    @(negedge clk); en = 0; din = 1;
    repeat (3) begin @(posedge clk); #1; check(PAT, "hold-en0"); end

    // --- 继续移位：喂 0，老数据整体左移一格 ---
    @(negedge clk); en = 1; din = 0;
    @(posedge clk); #1; check(8'h64, "shift-out-1");   // 1011_0010 -> 0110_0100

    // --- 再喂 WIDTH 个 0，老数据全部移出 ---
    for (i = 0; i < WIDTH; i = i + 1) begin
      @(negedge clk); en = 1; din = 0;
      @(posedge clk); #1;
    end
    check(8'h00, "shift-out-all");

    if (err == 0) $display(">>> tb_shift PASS");
    else          $display(">>> tb_shift FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #3000 $display(">>> tb_shift TIMEOUT"); $finish; end
endmodule
