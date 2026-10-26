// 临时资源/时序评估顶层（仅 nextpnr 用，不进版本库）
// engine_top + 128x8 同步样本 BRAM + 自动起帧；只暴露 clk/rst_n/probe。
module engine_fit_top (
  input  wire clk,
  input  wire rst_n,
  output reg  probe
);

  reg         eng_start;
  wire        eng_busy, eng_done;
  wire [2:0]  eng_class;
  wire [6:0]  smp_addr;
  wire signed [7:0] smp_data;

  // ---------------- 样本 BRAM（同步读 1 拍）----------------
  reg signed [7:0] smp_ram [0:127];
  reg signed [7:0] smp_q;
  integer i;
  initial begin
    for (i = 0; i < 128; i = i + 1)
      smp_ram[i] = i[6:0] - 7'sd64;
  end
  always @(posedge clk) smp_q <= smp_ram[smp_addr];
  assign smp_data = smp_q;

  engine_top #(
    .N(128), .T(16), .AW(7), .PW1(16), .PW2(16), .LP(8)
  ) u_eng (
    .clk_eng   (clk),
    .eng_rst_n (rst_n),
    .eng_start (eng_start),
    .eng_busy  (eng_busy),
    .eng_done  (eng_done),
    .eng_class (eng_class),
    .smp_addr  (smp_addr),
    .smp_data  (smp_data)
  );

  // 空闲时每隔一段自动起一帧
  reg [11:0] gap;
  reg [23:0] tick;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eng_start <= 1'b0;
      gap       <= 12'd0;
      tick      <= 24'd0;
      probe     <= 1'b0;
    end else begin
      eng_start <= 1'b0;
      tick      <= tick + 1'b1;
      probe     <= tick[23] ^ eng_busy ^ eng_done ^ eng_class[0];
      if (!eng_busy) begin
        if (gap == 12'd0) begin
          eng_start <= 1'b1;
          gap       <= 12'd4095;
        end else
          gap <= gap - 1'b1;
      end
    end
  end

endmodule
