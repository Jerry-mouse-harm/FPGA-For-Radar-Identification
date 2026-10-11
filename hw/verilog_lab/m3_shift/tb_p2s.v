`timescale 1ns/1ns
// tb_p2s: 并串转换判分台（自动 PASS/FAIL）
// 判据：空闲 dout=0；load 之后连续 WIDTH 拍，dout 依次是 din 的
//       WIDTH-1 → 0 位（最高位先出）；再下一拍 busy=0 且 dout=0。
// 用例含 8'h01 / 8'h80 两个边界（只有最低位 / 只有最高位是 1）
module tb_p2s;
  localparam WIDTH = 8;

  reg clk = 0;
  reg rst_n = 0;
  reg load = 0;
  reg [WIDTH-1:0] din = 0;
  wire dout;
  wire busy;
  integer err = 0;

  p2s #(.WIDTH(WIDTH)) u_dut (
    .clk(clk), .rst_n(rst_n), .load(load), .din(din), .dout(dout), .busy(busy)
  );

  always #5 clk = ~clk;

  // 送一个并行字，并在每一拍核对串行输出
  task send(input [WIDTH-1:0] d, input [8*16-1:0] msg);
    integer i;
    begin
      @(negedge clk); load = 1'b1; din = d;
      @(posedge clk); #1;                        // load 被采样那一拍: dout=d[WIDTH-1]
      @(negedge clk); load = 1'b0;               // 载入脉冲只留 1 拍

      for (i = 0; i < WIDTH; i = i + 1) begin
        if (dout !== d[WIDTH-1-i]) begin
          $display("FAIL %0s bit%0d @%0t: dout=%0b (expect %0b)",
                   msg, i, $time, dout, d[WIDTH-1-i]);
          err = err + 1;
        end
        if (i == 0 && busy !== 1'b1) begin
          $display("FAIL %0s busy @%0t: busy=%0b (expect 1)", msg, $time, busy);
          err = err + 1;
        end
        @(posedge clk); #1;                      // 走到下一拍（最后一次走到收工那一拍）
      end

      // 收工后：busy 落 0，dout 归 0
      if (busy !== 1'b0 || dout !== 1'b0) begin
        $display("FAIL %0s tail @%0t: busy=%0b dout=%0b (expect 0/0)",
                 msg, $time, busy, dout);
        err = err + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_p2s.vcd");
    $dumpvars(0, tb_p2s);

    rst_n = 0;
    #20 rst_n = 1;

    // 空闲检查
    @(negedge clk); #1;
    if (busy !== 1'b0 || dout !== 1'b0) begin
      $display("FAIL idle @%0t: busy=%0b dout=%0b (expect 0/0)", $time, busy, dout);
      err = err + 1;
    end

    send(8'hB2, "B2");    // 1011_0010
    send(8'h5A, "5A");    // 0101_1010
    send(8'h01, "01");    // 0000_0001
    send(8'h80, "80");    // 1000_0000

    if (err == 0) $display(">>> tb_p2s PASS");
    else          $display(">>> tb_p2s FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #3000 $display(">>> tb_p2s TIMEOUT"); $finish; end
endmodule
