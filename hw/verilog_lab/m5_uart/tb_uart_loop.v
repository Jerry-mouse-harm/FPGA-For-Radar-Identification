`timescale 1ns/1ns
// tb_uart_loop: uart_tx → uart_rx 直连环回验收（自动 PASS/FAIL）
//
// 为什么还要这个 tb：tx/rx 各自 PASS 只说明"各自符合自己的规格"，
//   不说明两者的**位序/位宽约定**一致（都是 LSB 先、都是 8N1 才对得上）。
//   这里把 tx 的输出直接接到 rx 的输入，看能不能原样还原 —— 这才是端到端正确。
module tb_uart_loop;
  localparam CLK_FREQ = 50_000_000;
  localparam BAUD     = 115200;
  localparam DIV      = CLK_FREQ / BAUD;     // 434
  localparam NWORD    = 5;

  reg clk = 0;
  reg rst_n = 0;
  reg tx_start = 0;
  reg [7:0] tx_data = 0;
  wire tx, busy;
  wire [7:0] dout;
  wire valid;

  integer err = 0;
  integer w, k, got;

  reg [7:0] WORDS [0:NWORD-1];

  uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
    .clk(clk), .rst_n(rst_n), .tx_start(tx_start), .tx_data(tx_data),
    .tx(tx), .busy(busy)
  );

  uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
    .clk(clk), .rst_n(rst_n), .rx(tx), .dout(dout), .valid(valid)
  );

  always #10 clk = ~clk;

  initial begin
    $dumpfile("tb_uart_loop.vcd");
    $dumpvars(0, tb_uart_loop);

    WORDS[0] = 8'hB2;    // 1011_0010
    WORDS[1] = 8'h5A;    // 0101_1010
    WORDS[2] = 8'h81;    // 1000_0001（最高/最低位都是 1，位序搞反就露馅）
    WORDS[3] = 8'h00;
    WORDS[4] = 8'hFF;

    rst_n = 0;
    #100 rst_n = 1;

    for (w = 0; w < NWORD; w = w + 1) begin
      @(negedge clk); tx_start = 1'b1; tx_data = WORDS[w];
      @(posedge clk); #1;
      tx_start = 1'b0;

      // 等 rx 还原（帧长 10 位，给 12 位时间的裕量）
      got = 0;
      for (k = 0; k < 12*DIV; k = k + 1) begin
        @(posedge clk); #1;
        if (valid === 1'b1) begin
          got = got + 1;
          if (dout !== WORDS[w]) begin
            $display("FAIL word%0d dout @%0t: dout=%b (expect %b)", w, $time, dout, WORDS[w]);
            err = err + 1;
          end
        end
      end
      if (got !== 1) begin
        $display("FAIL word%0d valid @%0t: valid 脉冲数=%0d (expect 1)", w, $time, got);
        err = err + 1;
      end

      // 发送侧必须已经收工，下一次才能再发
      if (busy !== 1'b0) begin
        $display("FAIL word%0d busy @%0t: busy=%0b (expect 0)", w, $time, busy);
        err = err + 1;
      end
    end

    if (err == 0) $display(">>> tb_uart_loop PASS (tx→rx 位序自洽, %0d 个字全部还原)", NWORD);
    else          $display(">>> tb_uart_loop FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #5_000_000 $display(">>> tb_uart_loop TIMEOUT"); $finish; end
endmodule
