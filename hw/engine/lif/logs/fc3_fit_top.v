// 临时资源评估顶层（仅 nextpnr 用，不进版本库）
// Conv1 -> Conv2 -> FC1/LIF3 -> Readout 全链级联，检查四层能否在 GW2AR-18 上
// 共存并跑 27MHz。LFSR 随机激励 + 1-bit 探针，只暴露 clk/rst_n/probe。
module fc3_fit_top (
  input  wire clk,
  input  wire rst_n,
  output reg  probe
);
  reg  [127:0] lfsr;
  wire [127:0] nxt_lfsr = {lfsr[126:0], lfsr[127] ^ lfsr[125] ^ lfsr[124] ^ lfsr[123]};

  wire busy1, done1, ov1;
  wire [2:0]   och1;
  wire [3:0]   ost1;
  wire [127:0] osp1;

  wire busy2, done2, ov2;
  wire [3:0] och2, ost2;
  wire [63:0] osp2;

  wire busy3, fs3, sv3, fd3;
  wire [31:0] spk3;

  wire busy4, done4;
  wire [2:0]  cls4;
  wire signed [99:0] lg4;

  reg [127:0] sink;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin lfsr <= 128'h1; sink <= 128'd0; probe <= 1'b0; end
    else begin
      lfsr  <= nxt_lfsr;
      sink  <= sink ^ osp1 ^ {64'd0, osp2} ^ {96'd0, spk3}
                    ^ {64'd0, spk3, busy4, done4, cls4, fd3, sv3, fs3,
                       busy3, busy2, done2, ov2, och2, ost2,
                       busy1, done1, ov1, och1, ost1};
      probe <= ^sink;
    end

  conv1_array #(
    .N(128), .T(16), .C(8), .K(5), .PW(16), .VW(16), .XW(16), .TW(16)
  ) u_c1 (
    .clk(clk), .rst_n(rst_n),
    .in_valid(lfsr[0]), .in_spike(lfsr),
    .busy(busy1), .done(done1),
    .out_valid(ov1), .out_ch(och1), .out_step(ost1), .out_spike(osp1)
  );

  conv2_array #(
    .NIN(128), .NP(64), .T(16), .CI(8), .CO(16), .K(5), .PW(16),
    .VW(16), .XW(16), .TW(16)
  ) u_c2 (
    .clk(clk), .rst_n(rst_n),
    .in_valid(ov1), .in_ch(och1), .in_step(ost1), .in_spike(osp1),
    .busy(busy2), .done(done2),
    .out_valid(ov2), .out_ch(och2), .out_step(ost2), .out_spike(osp2)
  );

  fc1_array #(
    .NPIN(64), .NP(32), .CI(16), .T(16), .NR(32),
    .VW(16), .XW(16), .TW(16)
  ) u_fc1 (
    .clk(clk), .rst_n(rst_n),
    .in_valid(ov2), .in_ch(och2), .in_step(ost2), .in_spike(osp2),
    .busy(busy3), .frame_start(fs3), .spk_valid(sv3),
    .spk_vec(spk3), .frame_done(fd3)
  );

endmodule
