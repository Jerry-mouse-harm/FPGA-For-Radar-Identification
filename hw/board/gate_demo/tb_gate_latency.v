`timescale 1ns/1ns
// tb_gate_latency —— 测"门控响应时延" vs SNR（记录用，非判分）。
//
// 拆成两段：
//   · 检测延迟（**SNR 相关**）：真实脉冲起始 (样本 26) → active 拉高，折算成**样本数**。
//   · 唤醒延迟（**与 SNR 无关**，FSM 决定）：t_wake（active↑→clk_eng 首沿）、
//     t_result（active↑→eng_done），都在 clk_sys 数拍。这里只报一次做记录。
//
// 总响应 = 检测延迟(样本) × 每样本拍数 + t_result(clk_sys 拍)。
//
// 用 din_valid 计数推帧内样本序（比盯 addr 的 delta-cycle 稳）。
module tb_gate_latency;
  localparam SMP_DIV = 3;          // 每样本 2^3=8 拍（仿真加速）
  reg  clk = 0;
  wire [5:0] leds;
  top #(.SMP_DIV(SMP_DIV)) dut (.clk(clk), .leds(leds));
  always #5 clk = ~clk;

  integer   dcnt = 0;              // din_valid 总计数
  reg       pact = 0;
  integer   dcnt_at_act = -1;      // active 首次拉高那一刻的 din_valid 计数
  integer   det_samples;
  integer   tw, tr;

  always @(posedge clk) if (dut.rst_n && dut.din_valid) dcnt <= dcnt + 1;

  always @(posedge clk) if (dut.rst_n) begin
    if (dut.active && !pact && dcnt >= 256 && dcnt_at_act < 0) dcnt_at_act <= dcnt;
    pact <= dut.active;
  end

  initial begin
    wait (dut.rst_n == 1'b1);
    wait (dcnt_at_act >= 0);                   // 等稳态帧 active 拉高
    wait (dut.u_gate.result_valid == 1'b1);    // 等本帧唤醒跑完
    tw = dut.u_gate.t_wake;
    tr = dut.u_gate.t_result;
    det_samples = (dcnt_at_act % 128) - 26;    // 相对真实脉冲起始(样本 26)
    $display("LATENCY active_on_sample=%0d det_samples=%0d t_wake=%0d t_result=%0d",
             dcnt_at_act % 128, det_samples, tw, tr);
    $finish;
  end
  initial begin #500000 $display("LATENCY TIMEOUT(active 未拉高, 永不激活)"); $finish; end
endmodule
