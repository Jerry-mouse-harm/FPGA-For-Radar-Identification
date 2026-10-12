`timescale 1ns/1ns
// tb_gate_demo: 上板前先仿真验 demo 接线（SMP_DIV 调小 → 秒验）
//   场景 = signal_rom 循环播放真实常规脉冲（脉冲窗样本 26..63）。
//   1) active 拉高（检测到脉冲）→ clk_eng 应在跑（有沿）
//   2) active 落低（且上一拍唤醒跑完）→ clk_eng 必须停跳（0 沿）
//   3) 下一帧应能再次唤醒（可重复）
module tb_gate_demo;
  reg  clk = 0;
  wire [5:0] leds;

  integer err = 0, e0, e1;
  integer eng_edges  = 0;
  integer act_rises  = 0;
  reg     prev_active = 1'b0;

  top #(.SMP_DIV(3)) dut (.clk(clk), .leds(leds));

  always #5 clk = ~clk;
  always @(posedge dut.clk_eng) eng_edges = eng_edges + 1;
  always @(posedge clk) begin
    if (dut.active && !prev_active) act_rises = act_rises + 1;
    prev_active <= dut.active;
  end

  initial begin
    wait (dut.rst_n == 1'b1);
    $display("INFO t=%0t: 复位释放, 开始播放常规脉冲 (128 点/帧)", $time);

    // ---- 第一帧 ----
    wait (dut.active == 1'b1);
    $display("INFO t=%0t: active 拉高 (检测到脉冲)", $time);
    e0 = eng_edges; repeat (80) @(posedge clk); e1 = eng_edges;
    if (e1 - e0 < 20) begin
      $display("FAIL: active=1 时 clk_eng 几乎没跳 (%0d 沿)", e1 - e0); err = err + 1;
    end
    else $display("INFO active=1: clk_eng 跳了 %0d 沿", e1 - e0);

    wait (dut.active == 1'b0);
    $display("INFO t=%0t: active 落低 (回静息)", $time);
    repeat (200) @(posedge clk);        // 让在飞的唤醒跑完
    e0 = eng_edges; repeat (200) @(posedge clk); e1 = eng_edges;
    if (e1 - e0 !== 0) begin
      $display("FAIL: active=0 后 clk_eng 还在跳 (%0d 沿, expect 0)", e1 - e0); err = err + 1;
    end
    else $display("INFO active=0: clk_eng 停跳 (0 沿)");

    // ---- 第二帧：确认可重复唤醒 ----
    wait (dut.active == 1'b1);
    e0 = eng_edges; repeat (80) @(posedge clk); e1 = eng_edges;
    if (e1 - e0 < 20) begin
      $display("FAIL: 二次 active=1 时 clk_eng 没重新跑 (%0d 沿)", e1 - e0); err = err + 1;
    end
    else $display("INFO 二次 active=1: clk_eng 重新跑 (%0d 沿)", e1 - e0);

    wait (dut.active == 1'b0);
    repeat (200) @(posedge clk);
    e0 = eng_edges; repeat (200) @(posedge clk); e1 = eng_edges;
    if (e1 - e0 !== 0) begin
      $display("FAIL: 二次 active=0 后 clk_eng 还在跳 (%0d 沿)", e1 - e0); err = err + 1;
    end
    else $display("INFO 二次 active=0: clk_eng 停跳 (0 沿)");

    if (act_rises < 2) begin
      $display("FAIL: active 只跳起 %0d 次 (expect >=2)", act_rises); err = err + 1;
    end
    else $display("INFO: active 共跳起 %0d 次", act_rises);

    if (err == 0)
      $display(">>> tb_gate_demo PASS (真脉冲→clk_eng 跑, 静息→clk_eng 停, 可重复)");
    else
      $display(">>> tb_gate_demo FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #500000 $display(">>> tb_gate_demo TIMEOUT"); $finish; end
endmodule
