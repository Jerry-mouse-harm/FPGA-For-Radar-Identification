`timescale 1ns/1ns
// tb_uart_rx: UART 接收判分台（8N1, 自动 PASS/FAIL）
//
// 时钟 20ns（=50MHz），CLK_FREQ=50M / BAUD=115200 → DIV=434 拍/位。
// 判分台自己当"发送端"：在负沿摆位、每位保持 DIV 拍，起始位 0、数据位 LSB 先、停止位 1。
// 判据：
//   ① 收满一帧 → valid 必须**正好 1 拍**，且 dout == 发的字节
//   ② 帧与帧之间连续发（中间只隔 2 拍空闲）不能错位
//   ③ 半位宽的低电平毛刺不能产生 valid（起始位要"半位后复检仍为低"）
module tb_uart_rx;
  localparam CLK_FREQ = 50_000_000;
  localparam BAUD     = 115200;
  localparam DIV      = CLK_FREQ / BAUD;     // 434

  reg clk = 0;
  reg rst_n = 0;
  reg din = 1'b1;
  wire [7:0] dout;
  wire valid;
  integer err = 0;
  integer i, k, nvalid;

  uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_dut (
    .clk(clk), .rst_n(rst_n), .rx(din), .dout(dout), .valid(valid)
  );

  always #10 clk = ~clk;

  // 发一帧并核对
  task feed(input [7:0] d, input [8*16-1:0] msg);
    begin
      @(negedge clk); din = 1'b0;                     // 起始位
      repeat (DIV) @(posedge clk);

      for (i = 0; i < 8; i = i + 1) begin             // 数据位 LSB 先
        @(negedge clk); din = d[i];
        repeat (DIV) @(posedge clk);
      end

      @(negedge clk); din = 1'b1;                     // 停止位
      nvalid = 0;
      for (k = 0; k < DIV + 4; k = k + 1) begin
        @(posedge clk); #1;
        if (valid === 1'b1) begin
          nvalid = nvalid + 1;
          if (dout !== d) begin
            $display("FAIL %0s dout @%0t: dout=%b (expect %b)", msg, $time, dout, d);
            err = err + 1;
          end
        end
      end
      if (nvalid !== 1) begin
        $display("FAIL %0s valid-pulse @%0t: valid 脉冲数=%0d (expect 1)", msg, $time, nvalid);
        err = err + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_uart_rx.vcd");
    $dumpvars(0, tb_uart_rx);

    rst_n = 0;
    #100 rst_n = 1;
    #1;
    if (valid !== 1'b0) begin
      $display("FAIL idle @%0t: valid=%0b (expect 0)", $time, valid);
      err = err + 1;
    end

    // ---- 用例 1: 普通字节（含连续两帧，验证帧间不错位）----
    feed(8'h55, "55");    // 0101_0101
    feed(8'hB2, "B2");    // 1011_0010
    feed(8'h5A, "5A");    // 0101_1010

    // ---- 用例 2: 边界字节 ----
    feed(8'h00, "00");    // 全 0：起始位后还得数满 8 位才停
    feed(8'hFF, "FF");    // 全 1
    feed(8'h01, "01");
    feed(8'h80, "80");
    feed(8'hFE, "FE");
    feed(8'h7F, "7F");

    // ---- 用例 3: 半位宽的毛刺不能产生 valid ----
    repeat (DIV) @(posedge clk);                 // din 先稳定在 1
    @(negedge clk); din = 1'b0;
    repeat (DIV/4) @(posedge clk);               // 低电平只保持 1/4 位
    @(negedge clk); din = 1'b1;
    for (k = 0; k < 2*DIV; k = k + 1) begin
      @(posedge clk); #1;
      if (valid !== 1'b0) begin
        $display("FAIL glitch @%0t: valid=%0b (expect 0)", $time, valid);
        err = err + 1;
      end
    end

    if (err == 0) $display(">>> tb_uart_rx PASS (10 帧全对, valid 单拍, 毛刺被滤)");
    else          $display(">>> tb_uart_rx FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #3_000_000 $display(">>> tb_uart_rx TIMEOUT"); $finish; end
endmodule
