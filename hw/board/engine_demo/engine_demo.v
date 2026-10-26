// engine_demo.v —— 真实 SNN 引擎上板最小闭环（P0-1）
//
// 干什么用的：把 hw/engine/lif 的四级引擎（encode_frontend → Conv1 → Conv2 →
//   FC1 → readout）整颗放上 Tang Nano 20K，上电后自动循环跑 9 帧真实样本，
//   用 LED 直接显示分类结果。验证"仿真 PASS 的引擎在真实器件上跑对"。
//
// 链路：
//   engine_sample_rom（9 帧 × 128 样本，同步读 1 拍）
//        │ smp_data
//        ▼
//   engine_top（PW1=8 / PW2=8 / LP=4，资源受限版）
//        │ eng_done / eng_class
//        ▼
//   帧序号 + LED 显示
//
// 时序：引擎一帧 ≈158791 拍 ≈5.88ms @27MHz；帧间隔 2^GAP_BITS 拍
//   （默认 2^23 ≈311ms），所以每类结果在 LED 上停约 0.31s，肉眼可读。
//
// 6 个 LED（低电平点亮，亮 = 0）：
//   leds[2:0] = ~class[2:0]   类别 0..4（3 位二进制）
//   leds[3]   = ~frame[0]     每出一帧翻转一次（证明在跑）
//   leds[4]   = ~busy         引擎计算期间亮（≈5.9ms，一瞬）
//   leds[5]   = ~tick[23]     0.31s 心跳参考，常亮/常灭交替
//
// 注意：上电复位（POR）拉 256 拍再放，避免依赖 GSR 初值。
module top #(
  parameter integer GAP_BITS = 23   // 帧间隔 = 2^GAP_BITS 拍（仿真可调小）
)(
  input        clk,                 // 27MHz (pin 4)
  output [5:0] leds                 // pin 15..20, 低电平点亮
);

  // ---------- 上电复位：约 256 拍后释放 ----------
  reg [7:0] por = 8'd0;
  wire      rst_n = &por;
  always @(posedge clk) if (!rst_n) por <= por + 1'b1;

  // ---------- 引擎 ----------
  reg               eng_start;
  wire              eng_busy, eng_done;
  wire [2:0]        eng_class;
  wire [6:0]        smp_addr;
  wire signed [7:0] smp_data;

  // ---------- 帧序号：0..8 循环，由 eng_done 推进 ----------
  reg [3:0] frame_idx;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      frame_idx <= 4'd0;
    else if (eng_done)
      frame_idx <= (frame_idx == 4'd8) ? 4'd0 : frame_idx + 1'b1;
  end

  wire [10:0] rom_addr = {frame_idx, smp_addr};

  engine_sample_rom u_rom (
    .clk  (clk),
    .addr (rom_addr),
    .dout (smp_data)
  );

  engine_top #(
    .N   (128),
    .T   (16),
    .AW  (7),
    .PW1 (8),
    .PW2 (8),
    .LP  (4)
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

  // ---------- 自动起帧：空闲满 2^GAP_BITS 拍就发一个 start 脉冲 ----------
  reg [GAP_BITS-1:0] gap;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      eng_start <= 1'b0;
      gap       <= {GAP_BITS{1'b0}};
    end else begin
      eng_start <= 1'b0;                  // 默认单拍
      if (!eng_busy) begin
        if (gap == {GAP_BITS{1'b0}}) begin
          eng_start <= 1'b1;
          gap       <= {GAP_BITS{1'b1}};
        end else
          gap <= gap - 1'b1;
      end
    end
  end

  // ---------- LED 显示 ----------
  reg [23:0] tick;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) tick <= 24'd0;
    else        tick <= tick + 1'b1;

  assign leds[2:0] = ~eng_class;
  assign leds[3]   = ~frame_idx[0];
  assign leds[4]   = ~eng_busy;
  assign leds[5]   = ~tick[23];

endmodule
