// 本文件由 gen_signal_rom.py 自动生成，请勿手改。
// 常规脉冲 Pulse: fc=2.0MHz tau=0.30 t0=0.20 SNR=20dB, 128 点 @10MHz
// 预处理: 零均值单位方差 → din = round(clip(x,-4,4)*16)，范围 [-35,44]
// truth = 脉冲窗样本 [26,64) = 该激活
// 地址 addr 0..127 循环播放，每拍给一个样本（din_valid 由顶层按分频给）。
module signal_rom (
  input  wire [6:0]        addr,
  output reg  signed [7:0] din,
  output reg               truth
);
  // din/truth 初值: 避免 addr=0 在仿真里读出 x (组合 case 的 delta-cycle 读前态),
  // 会污染检测器第一窗 (win_sum=x) → nf 走错分支. 上板有 GSR 初值, 但仿真必须显式给.
  initial begin din = 8'sd0; truth = 1'b0; end
  always @(*) begin
    case (addr)
      7'd0  : begin din = 8'h01; truth = 1'b0; end
      7'd1  : begin din = 8'h00; truth = 1'b0; end
      7'd2  : begin din = 8'h01; truth = 1'b0; end
      7'd3  : begin din = 8'h02; truth = 1'b0; end
      7'd4  : begin din = 8'h02; truth = 1'b0; end
      7'd5  : begin din = 8'hFF; truth = 1'b0; end
      7'd6  : begin din = 8'hFE; truth = 1'b0; end
      7'd7  : begin din = 8'hFF; truth = 1'b0; end
      7'd8  : begin din = 8'h00; truth = 1'b0; end
      7'd9  : begin din = 8'hFD; truth = 1'b0; end
      7'd10 : begin din = 8'h00; truth = 1'b0; end
      7'd11 : begin din = 8'hFE; truth = 1'b0; end
      7'd12 : begin din = 8'hFF; truth = 1'b0; end
      7'd13 : begin din = 8'h00; truth = 1'b0; end
      7'd14 : begin din = 8'h00; truth = 1'b0; end
      7'd15 : begin din = 8'h01; truth = 1'b0; end
      7'd16 : begin din = 8'h02; truth = 1'b0; end
      7'd17 : begin din = 8'h00; truth = 1'b0; end
      7'd18 : begin din = 8'h03; truth = 1'b0; end
      7'd19 : begin din = 8'hFF; truth = 1'b0; end
      7'd20 : begin din = 8'h01; truth = 1'b0; end
      7'd21 : begin din = 8'h02; truth = 1'b0; end
      7'd22 : begin din = 8'h01; truth = 1'b0; end
      7'd23 : begin din = 8'hFF; truth = 1'b0; end
      7'd24 : begin din = 8'hFF; truth = 1'b0; end
      7'd25 : begin din = 8'h00; truth = 1'b0; end
      7'd26 : begin din = 8'h0D; truth = 1'b1; end
      7'd27 : begin din = 8'hDE; truth = 1'b1; end
      7'd28 : begin din = 8'hDF; truth = 1'b1; end
      7'd29 : begin din = 8'h0D; truth = 1'b1; end
      7'd30 : begin din = 8'h2A; truth = 1'b1; end
      7'd31 : begin din = 8'h0D; truth = 1'b1; end
      7'd32 : begin din = 8'hE0; truth = 1'b1; end
      7'd33 : begin din = 8'hDE; truth = 1'b1; end
      7'd34 : begin din = 8'h0D; truth = 1'b1; end
      7'd35 : begin din = 8'h2B; truth = 1'b1; end
      7'd36 : begin din = 8'h0F; truth = 1'b1; end
      7'd37 : begin din = 8'hDD; truth = 1'b1; end
      7'd38 : begin din = 8'hE2; truth = 1'b1; end
      7'd39 : begin din = 8'h0F; truth = 1'b1; end
      7'd40 : begin din = 8'h2B; truth = 1'b1; end
      7'd41 : begin din = 8'h0D; truth = 1'b1; end
      7'd42 : begin din = 8'hDF; truth = 1'b1; end
      7'd43 : begin din = 8'hE1; truth = 1'b1; end
      7'd44 : begin din = 8'h10; truth = 1'b1; end
      7'd45 : begin din = 8'h2C; truth = 1'b1; end
      7'd46 : begin din = 8'h0F; truth = 1'b1; end
      7'd47 : begin din = 8'hE0; truth = 1'b1; end
      7'd48 : begin din = 8'hDD; truth = 1'b1; end
      7'd49 : begin din = 8'h0D; truth = 1'b1; end
      7'd50 : begin din = 8'h2A; truth = 1'b1; end
      7'd51 : begin din = 8'h0B; truth = 1'b1; end
      7'd52 : begin din = 8'hE0; truth = 1'b1; end
      7'd53 : begin din = 8'hE0; truth = 1'b1; end
      7'd54 : begin din = 8'h0E; truth = 1'b1; end
      7'd55 : begin din = 8'h27; truth = 1'b1; end
      7'd56 : begin din = 8'h0C; truth = 1'b1; end
      7'd57 : begin din = 8'hDF; truth = 1'b1; end
      7'd58 : begin din = 8'hDD; truth = 1'b1; end
      7'd59 : begin din = 8'h10; truth = 1'b1; end
      7'd60 : begin din = 8'h29; truth = 1'b1; end
      7'd61 : begin din = 8'h0E; truth = 1'b1; end
      7'd62 : begin din = 8'hDF; truth = 1'b1; end
      7'd63 : begin din = 8'hE2; truth = 1'b1; end
      7'd64 : begin din = 8'h02; truth = 1'b0; end
      7'd65 : begin din = 8'h01; truth = 1'b0; end
      7'd66 : begin din = 8'hFD; truth = 1'b0; end
      7'd67 : begin din = 8'h00; truth = 1'b0; end
      7'd68 : begin din = 8'h01; truth = 1'b0; end
      7'd69 : begin din = 8'h02; truth = 1'b0; end
      7'd70 : begin din = 8'hFF; truth = 1'b0; end
      7'd71 : begin din = 8'h03; truth = 1'b0; end
      7'd72 : begin din = 8'hFE; truth = 1'b0; end
      7'd73 : begin din = 8'hFF; truth = 1'b0; end
      7'd74 : begin din = 8'h02; truth = 1'b0; end
      7'd75 : begin din = 8'h00; truth = 1'b0; end
      7'd76 : begin din = 8'h04; truth = 1'b0; end
      7'd77 : begin din = 8'h01; truth = 1'b0; end
      7'd78 : begin din = 8'hFF; truth = 1'b0; end
      7'd79 : begin din = 8'h00; truth = 1'b0; end
      7'd80 : begin din = 8'hFF; truth = 1'b0; end
      7'd81 : begin din = 8'hFE; truth = 1'b0; end
      7'd82 : begin din = 8'h01; truth = 1'b0; end
      7'd83 : begin din = 8'h01; truth = 1'b0; end
      7'd84 : begin din = 8'h02; truth = 1'b0; end
      7'd85 : begin din = 8'hFF; truth = 1'b0; end
      7'd86 : begin din = 8'h03; truth = 1'b0; end
      7'd87 : begin din = 8'h00; truth = 1'b0; end
      7'd88 : begin din = 8'h03; truth = 1'b0; end
      7'd89 : begin din = 8'h00; truth = 1'b0; end
      7'd90 : begin din = 8'hFF; truth = 1'b0; end
      7'd91 : begin din = 8'h01; truth = 1'b0; end
      7'd92 : begin din = 8'h02; truth = 1'b0; end
      7'd93 : begin din = 8'h01; truth = 1'b0; end
      7'd94 : begin din = 8'hFF; truth = 1'b0; end
      7'd95 : begin din = 8'hFE; truth = 1'b0; end
      7'd96 : begin din = 8'hFE; truth = 1'b0; end
      7'd97 : begin din = 8'h01; truth = 1'b0; end
      7'd98 : begin din = 8'h02; truth = 1'b0; end
      7'd99 : begin din = 8'h00; truth = 1'b0; end
      7'd100: begin din = 8'hFF; truth = 1'b0; end
      7'd101: begin din = 8'h02; truth = 1'b0; end
      7'd102: begin din = 8'hFE; truth = 1'b0; end
      7'd103: begin din = 8'hFF; truth = 1'b0; end
      7'd104: begin din = 8'h01; truth = 1'b0; end
      7'd105: begin din = 8'hFD; truth = 1'b0; end
      7'd106: begin din = 8'h01; truth = 1'b0; end
      7'd107: begin din = 8'hFF; truth = 1'b0; end
      7'd108: begin din = 8'h01; truth = 1'b0; end
      7'd109: begin din = 8'h00; truth = 1'b0; end
      7'd110: begin din = 8'h01; truth = 1'b0; end
      7'd111: begin din = 8'h01; truth = 1'b0; end
      7'd112: begin din = 8'hFF; truth = 1'b0; end
      7'd113: begin din = 8'h03; truth = 1'b0; end
      7'd114: begin din = 8'h02; truth = 1'b0; end
      7'd115: begin din = 8'h02; truth = 1'b0; end
      7'd116: begin din = 8'h02; truth = 1'b0; end
      7'd117: begin din = 8'h02; truth = 1'b0; end
      7'd118: begin din = 8'h02; truth = 1'b0; end
      7'd119: begin din = 8'h00; truth = 1'b0; end
      7'd120: begin din = 8'hFE; truth = 1'b0; end
      7'd121: begin din = 8'h00; truth = 1'b0; end
      7'd122: begin din = 8'hFF; truth = 1'b0; end
      7'd123: begin din = 8'hFE; truth = 1'b0; end
      7'd124: begin din = 8'h01; truth = 1'b0; end
      7'd125: begin din = 8'hFF; truth = 1'b0; end
      7'd126: begin din = 8'hFF; truth = 1'b0; end
      7'd127: begin din = 8'hFF; truth = 1'b0; end
      default: begin din = 8'h00; truth = 1'b0; end
    endcase
  end
endmodule
