`timescale 1ns/1ns
// tb_sample_to_n: 定点样本 → 脉冲数 n 判分台（纯组合, 自动 PASS/FAIL）
//
// 金标准 sample_n.hex 由 gen_vectors.py 调用**项目自己的** encode_input(mode='spread') 生成，
// 不是手抄公式 —— 所以这里过 = 硬件映射和训练/部署同域（LOG.md 的铁律）。
// 每行 4 位十六进制 = {din[7:0](有符号), n[7:0]}
// 覆盖: 负向钳位(-128/-127/-64) / 正向钳位(63/64/127) / 零 / 正负尾数(尾数 5,6,7 才能
//       区分"加半 LSB 四舍五入"和"直接截断")
module tb_sample_to_n;
  localparam NV = 27;

  reg  signed [7:0] din = 0;
  wire [4:0]        n;
  integer err = 0;
  integer i, got, exp_n;

  reg [15:0] vec [0:NV-1];

  sample_to_n u_dut (.din(din), .n(n));

  initial begin
    $dumpfile("tb_sample_to_n.vcd");
    $dumpvars(0, tb_sample_to_n);
    $readmemh("sample_n.hex", vec);

    for (i = 0; i < NV; i = i + 1) begin
      din = vec[i][15:8];          // 有符号 8 位, 直接就是 x*16
      #1;
      exp_n = vec[i][7:0];
      got   = n;
      if (got !== exp_n) begin
        $display("FAIL #%0d din=%0d: n=%0d (expect %0d)", i, din, got, exp_n);
        err = err + 1;
      end
    end

    if (err == 0) $display(">>> tb_sample_to_n PASS (%0d 个样本全对, 含两端钳位)", NV);
    else          $display(">>> tb_sample_to_n FAIL (err=%0d)", err);
    $finish;
  end
endmodule
