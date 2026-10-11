`timescale 1ns/1ns
// tb_s2p: 串并转换判分台（自动 PASS/FAIL）
// 判据用"独立 oracle"算出来，跟你的实现无关：连喂 NFRAME*WIDTH 位，
//   每一拍：valid 只应在"刚好凑满 WIDTH 位"的那一拍为 1；
//   valid=1 时 dout 应等于那 WIDTH 位组成的字（高位先收 → 落在高位）。
// 连续喂 3 帧，顺便验证帧尾/帧头衔接不错位。
module tb_s2p;
  localparam WIDTH  = 8;
  localparam NFRAME = 3;
  localparam NTOT   = NFRAME * WIDTH;
  localparam [NTOT-1:0] STREAM = {8'hB2, 8'h5A, 8'hF0};   // 24 位，从高位开始喂

  reg clk = 0;
  reg rst_n = 0;
  reg din = 0;
  wire [WIDTH-1:0] dout;
  wire valid;
  integer err = 0;
  integer j;

  s2p #(.WIDTH(WIDTH)) u_dut (.clk(clk), .rst_n(rst_n), .din(din), .dout(dout), .valid(valid));

  always #5 clk = ~clk;

  initial begin
    $dumpfile("tb_s2p.vcd");
    $dumpvars(0, tb_s2p);

    rst_n = 0;
    #20 rst_n = 1;

    for (j = 0; j < NTOT; j = j + 1) begin
      @(negedge clk); din = STREAM[NTOT-1-j];
      @(posedge clk); #1;

      if ((j + 1) % WIDTH == 0) begin
        // 这一拍正好收满第 (j/WIDTH+1) 帧
        if (valid !== 1'b1) begin
          $display("FAIL frame%0d valid @%0t: valid=%0b (expect 1)", j/WIDTH, $time, valid);
          err = err + 1;
        end
        if (dout !== STREAM[NTOT-1-(j/WIDTH)*WIDTH -: WIDTH]) begin
          $display("FAIL frame%0d dout @%0t: dout=%b (expect %b)", j/WIDTH, $time, dout,
                   STREAM[NTOT-1-(j/WIDTH)*WIDTH -: WIDTH]);
          err = err + 1;
        end
      end
      else if (valid !== 1'b0) begin
        $display("FAIL bit%0d valid-early @%0t: valid=%0b (expect 0)", j, $time, valid);
        err = err + 1;
      end
    end

    if (err == 0) $display(">>> tb_s2p PASS (3 帧全对, valid 位置正确)");
    else          $display(">>> tb_s2p FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #3000 $display(">>> tb_s2p TIMEOUT"); $finish; end
endmodule
