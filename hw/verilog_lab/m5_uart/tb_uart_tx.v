`timescale 1ns/1ns
// tb_uart_tx: UART 发送判分台（8N1, 自动 PASS/FAIL）
//
// 时钟 20ns（=50MHz），配置 CLK_FREQ=50M / BAUD=115200 → DIV=434 拍/位。
// 判据：从"起始位起点那个正沿"开始，在每个**位边界**核对 tx：
//   [0]      起始位 = 0
//   [i+1]    数据位 = tx_data[i]（LSB 先发）
//   [9]      停止位 = 1
//   [10]     busy 落 0
// 另加三件事：空闲电平、busy 期间 tx_start 必须被忽略、换一组参数(DIV=1000)也得对。
module tb_uart_tx;
  localparam CLK_FREQ = 50_000_000;
  localparam BAUD     = 115200;
  localparam DIV      = CLK_FREQ / BAUD;      // 434

  localparam BAUD2    = 50_000;
  localparam DIV2     = CLK_FREQ / BAUD2;     // 1000（验"波特率可配"）

  reg clk = 0;
  reg rst_n = 0;
  integer err = 0;
  integer i, n;
  reg [7:0] pat;

  reg        tx_start = 0;
  reg [7:0]  tx_data  = 0;
  wire       tx, busy;

  reg        tx2_start = 0;
  reg [7:0]  tx2_data  = 0;
  wire       tx2, busy2;

  uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_dut (
    .clk(clk), .rst_n(rst_n), .tx_start(tx_start), .tx_data(tx_data),
    .tx(tx), .busy(busy)
  );

  uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD2)) u_dut2 (
    .clk(clk), .rst_n(rst_n), .tx_start(tx2_start), .tx_data(tx2_data),
    .tx(tx2), .busy(busy2)
  );

  always #10 clk = ~clk;

  // 发一个字节并逐位核对（返回时已停在帧尾、busy 刚落 0）
  task send(input [7:0] d, input [8*16-1:0] msg);
    begin
      @(negedge clk); tx_start = 1'b1; tx_data = d;
      @(posedge clk); #1;                  // T: 起始位起点
      tx_start = 1'b0;                     // 已采样, 立刻撤（只占这一拍）

      if (tx !== 1'b0 || busy !== 1'b1) begin
        $display("FAIL %0s start @%0t: tx=%0b busy=%0b (expect 0/1)", msg, $time, tx, busy);
        err = err + 1;
      end

      for (i = 0; i < 8; i = i + 1) begin
        repeat (DIV) @(posedge clk); #1;   // 下一个位边界
        if (tx !== d[i]) begin
          $display("FAIL %0s bit%0d @%0t: tx=%0b (expect %0b)", msg, i, $time, tx, d[i]);
          err = err + 1;
        end
      end

      repeat (DIV) @(posedge clk); #1;     // 停止位边界
      if (tx !== 1'b1) begin
        $display("FAIL %0s stop @%0t: tx=%0b (expect 1)", msg, $time, tx);
        err = err + 1;
      end

      repeat (DIV) @(posedge clk); #1;     // 帧尾
      if (busy !== 1'b0) begin
        $display("FAIL %0s busy-tail @%0t: busy=%0b (expect 0)", msg, $time, busy);
        err = err + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_uart_tx.vcd");
    $dumpvars(0, tb_uart_tx);

    rst_n = 0;
    #100 rst_n = 1;
    #1;
    if (tx !== 1'b1 || busy !== 1'b0) begin
      $display("FAIL idle @%0t: tx=%0b busy=%0b (expect 1/0)", $time, tx, busy);
      err = err + 1;
    end
    if (tx2 !== 1'b1 || busy2 !== 1'b0) begin
      $display("FAIL idle2 @%0t: tx2=%0b busy2=%0b (expect 1/0)", $time, tx2, busy2);
      err = err + 1;
    end

    // ---- 用例 1: 普通字节 ----
    send(8'hB2, "B2");    // 1011_0010
    send(8'h5A, "5A");    // 0101_1010

    // ---- 用例 2: 边界（最低位/最高位单独为 1）----
    send(8'h01, "01");
    send(8'h80, "80");
    send(8'h00, "00");

    // ---- 用例 3: 帧尾后不误触发 ----
    repeat (DIV) @(posedge clk); #1;
    if (tx !== 1'b1) begin
      $display("FAIL idle-after @%0t: tx=%0b (expect 1)", $time, tx);
      err = err + 1;
    end

    // ---- 用例 4: busy 期间 tx_start 必须被忽略 ----
    // 发 0x3C(0011_1100)，在 bit2 中间插一个"忙时请求"(0xFF)，它不得打断也不得排队。
    pat = 8'h3C;
    @(negedge clk); tx_start = 1'b1; tx_data = pat;
    @(posedge clk); #1;
    tx_start = 1'b0;
    for (i = 0; i < 3; i = i + 1) begin
      repeat (DIV) @(posedge clk); #1;
      if (tx !== pat[i]) begin
        $display("FAIL intr bit%0d @%0t: tx=%0b (expect %0b)", i, $time, tx, pat[i]);
        err = err + 1;
      end
    end
    // 现在刚过 bit2 边界; 插一个正沿的忙时请求
    @(negedge clk); tx_start = 1'b1; tx_data = 8'hFF;
    @(posedge clk); #1;                 // 这个正沿落在 busy 中 → 应被忽略
    tx_start = 1'b0;
    // 上面多花了 1 拍，所以到下一个位边界只等 DIV-1 拍
    repeat (DIV-1) @(posedge clk); #1;
    for (i = 3; i < 8; i = i + 1) begin
      if (tx !== pat[i]) begin
        $display("FAIL intr bit%0d @%0t: tx=%0b (expect %0b)", i, $time, tx, pat[i]);
        err = err + 1;
      end
      repeat (DIV) @(posedge clk); #1;
    end
    if (tx !== 1'b1) begin
      $display("FAIL intr stop @%0t: tx=%0b (expect 1)", $time, tx);
      err = err + 1;
    end
    repeat (DIV) @(posedge clk); #1;
    if (busy !== 1'b0) begin
      $display("FAIL intr busy-tail @%0t: busy=%0b (expect 0)", $time, busy);
      err = err + 1;
    end
    // 被忽略的请求不能在后面冒出来: 再空闲 2 位时间内 tx 必须一直是 1
    for (i = 0; i < 2*DIV; i = i + 1) begin
      @(posedge clk); #1;
      if (tx !== 1'b1) begin
        $display("FAIL intr ghost-frame @%0t: tx=%0b (expect 1)", $time, tx);
        err = err + 1;
      end
    end

    // ---- 用例 5: 换 BAUD(50k → DIV=1000) 参数也得对 ----
    // 发 0x00: 起始位 + 8 个 0 = 连续低 9*DIV2 拍, 之后才是停止位
    @(negedge clk); tx2_start = 1'b1; tx2_data = 8'h00;
    @(posedge clk); #1;
    tx2_start = 1'b0;
    n = 0;
    while (tx2 !== 1'b1 && n < 4*9*DIV2) begin
      @(posedge clk); #1;
      n = n + 1;
    end
    if (n !== 9*DIV2) begin
      $display("FAIL baud-cfg @%0t: 低电平持续 %0d 拍 (expect %0d)", $time, n, 9*DIV2);
      err = err + 1;
    end
    if (busy2 !== 1'b1) begin
      $display("FAIL baud-cfg busy2 @%0t: busy2=%0b (expect 1)", $time, busy2);
      err = err + 1;
    end

    if (err == 0) $display(">>> tb_uart_tx PASS (帧格式/位序/忙标志/忙时忽略/波特率可配 全对)");
    else          $display(">>> tb_uart_tx FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #3_000_000 $display(">>> tb_uart_tx TIMEOUT"); $finish; end
endmodule
