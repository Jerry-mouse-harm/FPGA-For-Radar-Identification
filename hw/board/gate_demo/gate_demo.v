// gate_demo.v —— 门控 demo 顶层（上板用）：喂**真实常规脉冲**，肉眼确认
// "信号来 → clk_eng 跑 / 信号走 → clk_eng 停跳"。
//
// 数据来源：signal_rom.v（由 gen_signal_rom.py 生成）——一段真常规脉冲 Pulse
//   （fc=2MHz, tau=0.3, t0=0.2, SNR=20dB, 128 点 @10MHz），走项目同一条预处理
//   （零均值单位方差）→ M6 定点 din = round(clip(x,-4,4)*16)。
//   顶层每个样本连出 2^SMP_DIV 个 clk 拍（慢放到肉眼可辨），地址 0..127 循环。
//
// 链路：signal_rom → activity_detector → gate_ctrl → eng_stub（clk = clk_eng）。
//
// 6 个 LED（低电平点亮）：
//   leds[0]  truth        —— 亮 = **驱动侧真值**（脉冲窗内该激活）
//   leds[1]  active       —— 亮 = **检测器判为活动**（与 leds[0] 对照，A/B）
//   leds[2]  clk_sys 参考 —— 一直闪（常开时钟永不门控）
//   leds[5:3] clk_eng 计数 —— 活动时在走，静息时**冻住**（这就是"时钟停跳"）
//
// 注意：上电复位（POR）拉够拍再放，避免依赖 GSR 初值。
module top #(
  parameter SMP_DIV = 19      // 每样本 2^SMP_DIV 个 clk 拍；2^19≈19.4ms → 一帧 ≈ 2.5s
)(
  input        clk,           // 27MHz (pin 4)
  output [5:0] leds           // pin 15..20, 低电平点亮
);

  // ---------- 上电复位（POR）：约 256 拍后释放 ----------
  reg [7:0] por = 8'd0;
  wire      rst_n = &por;
  always @(posedge clk) if (!rst_n) por <= por + 1'b1;

  // ---------- 1) 样本播放：每 2^SMP_DIV 拍出一个样本，地址 0..127 循环 ----------
  reg [23:0] smp_cnt = 24'd0;
  always @(posedge clk)
    if (!rst_n) smp_cnt <= 24'd0;          // 复位期间冻住, 放出来后从样本 0 开始
    else        smp_cnt <= smp_cnt + 1'b1;
  wire       din_valid = (smp_cnt[SMP_DIV-1:0] == 0);   // 每隔 2^SMP_DIV 拍一个样本

  reg [6:0]  addr = 7'd0;
  always @(posedge clk)
    if (!rst_n)         addr <= 7'd0;
    else if (din_valid) addr <= (addr == 7'd127) ? 7'd0 : addr + 7'd1;

  wire signed [7:0] din;
  wire              truth;                 // 驱动侧真值（脉冲窗内 = 1）
  signal_rom u_rom (.addr(addr), .din(din), .truth(truth));

  // ---------- 2) 活动检测（常开域 clk_sys）----------
  // ADAPT=1：噪声底自适应阈值（th_on=2·nf, th_off=1.5·nf）——不用按 SNR 手调。
  wire active;
  activity_detector #(.W(16), .ADAPT(1)) u_ad (
    .clk(clk), .rst_n(rst_n), .din(din), .din_valid(din_valid), .active(active)
  );

  // ---------- 3) 门控 FSM（常开域）----------
  wire        clk_eng, eng_rst_n, eng_start, eng_busy, eng_done;
  wire [2:0]  eng_class;
  wire        result_valid;
  wire [2:0]  result_class;
  wire [15:0] t_wake, t_result;

  gate_ctrl u_gate (
    .clk_sys(clk), .rst_n(rst_n), .active(active),
    .clk_eng(clk_eng), .eng_rst_n(eng_rst_n), .eng_start(eng_start),
    .eng_busy(eng_busy), .eng_done(eng_done), .eng_class(eng_class),
    .result_valid(result_valid), .result_class(result_class),
    .t_wake(t_wake), .t_result(t_result)
  );

  // ---------- 4) stub 引擎（门控域 clk_eng）----------
  eng_stub u_eng (
    .clk(clk_eng), .rst_n(eng_rst_n), .start(eng_start),
    .busy(eng_busy), .done(eng_done), .cls(eng_class)
  );

  // ---------- 5) 指示灯 ----------
  reg [25:0] sys_cnt = 26'd0;              // clk_sys 域, 永不停
  always @(posedge clk)       sys_cnt <= sys_cnt + 1'b1;

  reg [25:0] eng_cnt = 26'd0;              // clk_eng 域, 门控 → 会冻住
  always @(posedge clk_eng)   eng_cnt <= eng_cnt + 1'b1;

  assign leds[0]   = ~truth;               // 亮 = 信号该在
  assign leds[1]   = ~active;              // 亮 = 检测器说在
  assign leds[2]   = sys_cnt[24];          // 参考: 一直闪
  assign leds[5:3] = eng_cnt[25:23];       // clk_eng 里程表: 活动走, 静息冻

endmodule
