`timescale 1ns/1ns
// tb_loop: p2s → s2p 环回验收（自动 PASS/FAIL）
//
// 为什么还要这个 tb：单模块各自 PASS 只说明"各自符合自己的规格"，
//   不说明两者的**位序约定**一致（都是 MSB-first 才对得上）。
//   这里把 s2p 刚收到的字节立刻交给 p2s 再发一遍，
//   看能不能还原成同一个字 —— 这才是端到端正确。
//
// 注意：s2p 没有使能、连续接收，它的"帧相位"由复位释放的时刻决定。
//   所以这里给 s2p 单独一根复位 rst_s，每一轮重新定相位（并排放一个 rst_p 给 p2s）。
module tb_loop;
  localparam WIDTH = 8;
  localparam NWORD = 3;

  reg clk = 0;
  reg rst_p = 0;                    // p2s 的复位
  reg rst_s = 0;                    // s2p 的复位（同时用来定帧相位）
  reg load = 0;
  reg [WIDTH-1:0] din_p = 0;
  reg din_s = 0;

  wire dout_p, busy_p;
  wire [WIDTH-1:0] dout_s;
  wire valid_s;

  p2s #(.WIDTH(WIDTH)) u_p2s (
    .clk(clk), .rst_n(rst_p), .load(load), .din(din_p), .dout(dout_p), .busy(busy_p)
  );
  s2p #(.WIDTH(WIDTH)) u_s2p (
    .clk(clk), .rst_n(rst_s), .din(din_s), .dout(dout_s), .valid(valid_s)
  );

  always #5 clk = ~clk;

  integer err = 0;
  integer w, j, k;
  reg [WIDTH-1:0] word;
  reg [WIDTH-1:0] WORDS [0:NWORD-1];

  initial begin
    $dumpfile("tb_loop.vcd");
    $dumpvars(0, tb_loop);

    WORDS[0] = 8'hB2;    // 1011_0010
    WORDS[1] = 8'h5A;    // 0101_1010
    WORDS[2] = 8'h81;    // 1000_0001（最高/最低位都是 1，位序搞反就露馅）

    rst_p = 0; rst_s = 0;
    #20 rst_p = 1;                    // p2s 复位一次就够

    for (w = 0; w < NWORD; w = w + 1) begin
      word = WORDS[w];

      // ---- 1) 串行喂给 s2p, 收下这个字节 ----
      @(negedge clk); rst_s = 0;      // 重新定相位
      repeat (2) @(posedge clk);

      @(negedge clk); rst_s = 1; din_s = word[WIDTH-1];
      @(posedge clk); #1;             // 第 1 次采样

      for (j = 1; j < WIDTH; j = j + 1) begin
        @(negedge clk); din_s = word[WIDTH-1-j];
        @(posedge clk); #1;
      end
      // 第 WIDTH 次采样后应产生 valid
      if (valid_s !== 1'b1 || dout_s !== word) begin
        $display("FAIL recv word%0d @%0t: valid=%0b dout=%b (expect 1/%b)",
                 w, $time, valid_s, dout_s, word);
        err = err + 1;
      end

      // ---- 2) 把这个字节交给 p2s 并行载入, 再逐位发出去 ----
      @(negedge clk); load = 1'b1; din_p = dout_s;
      @(posedge clk); #1;                       // P_L: 载入, dout_p=bit7
      @(negedge clk); load = 1'b0;

      for (k = 0; k < WIDTH; k = k + 1) begin
        if (dout_p !== word[WIDTH-1-k]) begin
          $display("FAIL send word%0d bit%0d @%0t: dout_p=%0b (expect %0b)",
                   w, k, $time, dout_p, word[WIDTH-1-k]);
          err = err + 1;
        end
        @(posedge clk); #1;
      end
    end

    if (err == 0) $display(">>> tb_loop PASS (p2s→s2p 位序自洽, %0d 个字全部还原)", NWORD);
    else          $display(">>> tb_loop FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #8000 $display(">>> tb_loop TIMEOUT"); $finish; end
endmodule
