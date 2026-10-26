// 临时资源评估顶层（仅 nextpnr 用，不进版本库）
// conv1_array 的 128+128 位接口超出 88 脚封装，这里用 LFSR 激励 + 1-bit 探针，
// 只暴露 clk/rst_n/probe 三个脚，保留阵列全部逻辑做真实布局布线。
module conv1_fit_top (
  input  wire clk,
  input  wire rst_n,
  output reg  probe
);
  reg [127:0] lfsr;
  reg [3:0]   tick;
  wire        busy, done, out_valid;
  wire [2:0]  out_ch;
  wire [3:0]  out_step;
  wire [127:0] out_spike;
  reg  [127:0] sink;
  wire [127:0] nxt_lfsr = {lfsr[126:0], lfsr[127] ^ lfsr[125] ^ lfsr[124] ^ lfsr[123]};

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin lfsr <= 128'h1; tick <= 0; sink <= 0; probe <= 0; end
    else begin
      lfsr <= nxt_lfsr;
      tick <= tick + 1'b1;
      sink <= sink ^ (out_spike + {124'd0, out_ch, out_step, done, busy, out_valid});
      probe <= ^sink;
    end

  conv1_array #(
    .N(128), .T(16), .C(8), .K(5), .PW(16), .VW(16), .XW(16), .TW(16)
  ) u_dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(lfsr[0]),
    .in_spike(lfsr),
    .busy(busy), .done(done),
    .out_valid(out_valid), .out_ch(out_ch), .out_step(out_step), .out_spike(out_spike)
  );
endmodule
