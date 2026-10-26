// 自动生成：tb/install_real_weights.py —— 请勿手改
// 读出层权重 ROM（真实低 SNR 精调部署权重，int8 定点）
// addr = r（0..31）；dout_w[8*c +: 8] = W2[c][r]；组合 case。

module readout_wrom (
  input  wire [4:0]       addr_r,
  output reg  [39:0]      dout_w,
  output wire signed [79:0] dout_b
);

  always @(*) begin
    case (addr_r)
      5'd0: dout_w = 40'h9f3d273eae;
      5'd1: dout_w = 40'ha719e72b1d;
      5'd2: dout_w = 40'h93f10f3f1f;
      5'd3: dout_w = 40'hb5ad2e9a31;
      5'd4: dout_w = 40'hbace490dc3;
      5'd5: dout_w = 40'hb1a02cca54;
      5'd6: dout_w = 40'h73d9a0aeb2;
      5'd7: dout_w = 40'h213fa0b8be;
      5'd8: dout_w = 40'h49bdc50ad9;
      5'd9: dout_w = 40'h9c17258159;
      5'd10: dout_w = 40'h4523c1bb84;
      5'd11: dout_w = 40'h9e2e9a203a;
      5'd12: dout_w = 40'hc49c8a8a7d;
      5'd13: dout_w = 40'h30d631c3c4;
      5'd14: dout_w = 40'ha6fc318d3f;
      5'd15: dout_w = 40'hab2ba73dcb;
      5'd16: dout_w = 40'habe8b44b24;
      5'd17: dout_w = 40'hc12331e903;
      5'd18: dout_w = 40'hbd87d1311a;
      5'd19: dout_w = 40'hc06320f8c6;
      5'd20: dout_w = 40'h3edba629e5;
      5'd21: dout_w = 40'h472ca3ad4c;
      5'd22: dout_w = 40'h42a4aca6bc;
      5'd23: dout_w = 40'h35aaf6aa40;
      5'd24: dout_w = 40'hb78751ad05;
      5'd25: dout_w = 40'h1ecf50aad1;
      5'd26: dout_w = 40'h9a06e62bf2;
      5'd27: dout_w = 40'hbada304206;
      5'd28: dout_w = 40'h9423032a20;
      5'd29: dout_w = 40'hbd2b340f9c;
      5'd30: dout_w = 40'ha862e3e503;
      5'd31: dout_w = 40'hbed24cc2fb;
      default: dout_w = 40'sd0;
    endcase
  end

  assign dout_b = {16'sd14, -16'sd11, -16'sd20, 16'sd16, -16'sd2};

endmodule
