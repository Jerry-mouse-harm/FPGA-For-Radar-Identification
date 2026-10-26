// 自动生成：src/export/export_int8.py —— 请勿手改
// Conv1 权重 ROM（真实低 SNR 精调部署权重，int8 定点）
// s_w = 0.0061532273；布局：0..39 = W[c][k]，40..47 = B[c]，48..55 = TH[c]
// 三端口都是组合读（case 实现，不依赖 $readmemh / BSRAM 原语）

module conv1_wrom (
  input  wire [5:0]        addr_w,
  input  wire [5:0]        addr_b,
  input  wire [5:0]        addr_t,
  output reg  signed [15:0] dout_w,
  output reg  signed [15:0] dout_b,
  output reg  signed [15:0] dout_t
);

  always @(*) begin
    case (addr_w)
      6'd0: dout_w = -16'sd112;  // W[0][0]
      6'd1: dout_w = -16'sd50;  // W[0][1]
      6'd2: dout_w = 16'sd77;  // W[0][2]
      6'd3: dout_w = 16'sd21;  // W[0][3]
      6'd4: dout_w = -16'sd24;  // W[0][4]
      6'd5: dout_w = -16'sd4;  // W[1][0]
      6'd6: dout_w = -16'sd22;  // W[1][1]
      6'd7: dout_w = 16'sd84;  // W[1][2]
      6'd8: dout_w = -16'sd90;  // W[1][3]
      6'd9: dout_w = 16'sd98;  // W[1][4]
      6'd10: dout_w = 16'sd6;  // W[2][0]
      6'd11: dout_w = 16'sd90;  // W[2][1]
      6'd12: dout_w = -16'sd108;  // W[2][2]
      6'd13: dout_w = -16'sd103;  // W[2][3]
      6'd14: dout_w = -16'sd28;  // W[2][4]
      6'd15: dout_w = -16'sd49;  // W[3][0]
      6'd16: dout_w = -16'sd30;  // W[3][1]
      6'd17: dout_w = 16'sd24;  // W[3][2]
      6'd18: dout_w = 16'sd126;  // W[3][3]
      6'd19: dout_w = 16'sd65;  // W[3][4]
      6'd20: dout_w = -16'sd98;  // W[4][0]
      6'd21: dout_w = -16'sd15;  // W[4][1]
      6'd22: dout_w = 16'sd8;  // W[4][2]
      6'd23: dout_w = -16'sd74;  // W[4][3]
      6'd24: dout_w = 16'sd4;  // W[4][4]
      6'd25: dout_w = 16'sd68;  // W[5][0]
      6'd26: dout_w = 16'sd4;  // W[5][1]
      6'd27: dout_w = -16'sd98;  // W[5][2]
      6'd28: dout_w = 16'sd64;  // W[5][3]
      6'd29: dout_w = 16'sd71;  // W[5][4]
      6'd30: dout_w = -16'sd32;  // W[6][0]
      6'd31: dout_w = 16'sd90;  // W[6][1]
      6'd32: dout_w = -16'sd73;  // W[6][2]
      6'd33: dout_w = 16'sd127;  // W[6][3]
      6'd34: dout_w = -16'sd7;  // W[6][4]
      6'd35: dout_w = 16'sd74;  // W[7][0]
      6'd36: dout_w = 16'sd81;  // W[7][1]
      6'd37: dout_w = -16'sd15;  // W[7][2]
      6'd38: dout_w = -16'sd69;  // W[7][3]
      6'd39: dout_w = -16'sd37;  // W[7][4]
      default: dout_w = 16'sd0;
    endcase

    case (addr_b)
      6'd40: dout_b = 16'sd32;  // B[0]
      6'd41: dout_b = -16'sd46;  // B[1]
      6'd42: dout_b = 16'sd57;  // B[2]
      6'd43: dout_b = -16'sd74;  // B[3]
      6'd44: dout_b = 16'sd82;  // B[4]
      6'd45: dout_b = -16'sd58;  // B[5]
      6'd46: dout_b = -16'sd49;  // B[6]
      6'd47: dout_b = -16'sd18;  // B[7]
      default: dout_b = 16'sd0;
    endcase

    case (addr_t)
      6'd48: dout_t = 16'sd68;  // TH[0]
      6'd49: dout_t = 16'sd68;  // TH[1]
      6'd50: dout_t = 16'sd68;  // TH[2]
      6'd51: dout_t = 16'sd68;  // TH[3]
      6'd52: dout_t = 16'sd68;  // TH[4]
      6'd53: dout_t = 16'sd68;  // TH[5]
      6'd54: dout_t = 16'sd68;  // TH[6]
      6'd55: dout_t = 16'sd68;  // TH[7]
      default: dout_t = 16'sd0;
    endcase
  end

endmodule
