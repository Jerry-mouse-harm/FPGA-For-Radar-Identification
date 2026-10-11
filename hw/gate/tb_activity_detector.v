`timescale 1ns/1ns
// tb_activity_detector: 活动检测判分台（自动 PASS/FAIL）
//
// 判据：窗内能量和 Σ|din|（W 个有效样本），≥TH_ON 置 active=1，≤TH_OFF 置 0，
//       中间带**保持**（滞回）。active 只在窗边界变、窗内恒定、din_valid=0 不计数。
//
// 用例覆盖：
//   W1  静息保持        Σ=128  ≤ TH_OFF          → 保持 0
//   W2  死区(现为0)     Σ=640  ∈(TH_OFF,TH_ON)   → 保持 0
//   W3  越阈            Σ=1280 ≥ TH_ON           → 翻 1
//   W4  死区(现为1)     Σ=640                    → 保持 1
//   W5  回落            Σ=128  ≤ TH_OFF          → 翻 0
//   W6  负样本|din|     din=-80 → Σ=1280         → 翻 1（取绝对値）
//   W7  回落                                     → 翻 0
//   W8  off-by-one      15×68 + 1×8 = 1028 ≥ TH_ON（漏算最后一个样本会停在 1020 < 阈值）
//   W9  回落                                     → 翻 0
//   W10 din_valid 门控  5有效+3无效+11有效 → 只算 16 个 → Σ=1280 → 翻 1
//   W11 回落                                     → 翻 0
module tb_activity_detector;
  localparam W      = 16;
  localparam TH_ON  = 1024;
  localparam TH_OFF = 512;

  reg              clk = 0, rst_n = 0, din_valid = 0;
  reg signed [7:0] din = 0;
  wire             active;

  integer err = 0, k;
  reg     cur_active;

  activity_detector #(.W(W), .TH_ON(TH_ON), .TH_OFF(TH_OFF)) dut (
    .clk(clk), .rst_n(rst_n), .din(din), .din_valid(din_valid), .active(active)
  );

  always #5 clk = ~clk;

  // 一个样本：负沿摆 din/valid，正沿让 DUT 采样，再 #1 读输出
  task send(input signed [7:0] d, input v);
    begin
      @(negedge clk); din = d; din_valid = v;
      @(posedge clk); #1;
    end
  endtask

  // 送一个"全同値"的窗，并检查窗内 active 恒定 + 窗末翻到 exp_after
  task win(input signed [7:0] d, input exp_after);
    begin
      for (k = 0; k < W; k = k + 1) begin
        send(d, 1'b1);
        if (k <= W - 2 && active !== cur_active) begin
          $display("FAIL mid-window @%0t (k=%0d): active=%0b (expect hold %0b)",
                   $time, k, active, cur_active);
          err = err + 1;
        end
      end
      if (active !== exp_after) begin
        $display("FAIL window-end @%0t: din=%0d active=%0b (expect %0b)",
                 $time, $signed(d), active, exp_after);
        err = err + 1;
      end
      cur_active = exp_after;
    end
  endtask

  initial begin
    $dumpfile("tb_activity_detector.vcd");
    $dumpvars(0, tb_activity_detector);

    // 复位: active 必须为 0
    rst_n = 0;
    repeat (3) @(posedge clk); #1;
    if (active !== 1'b0) begin
      $display("FAIL reset @%0t: active=%0b (expect 0)", $time, active);
      err = err + 1;
    end
    @(negedge clk); rst_n = 1;
    cur_active = 1'b0;

    win(8'sd8,  1'b0);   // W1 静息:  Σ=128  ≤ TH_OFF
    win(8'sd40, 1'b0);   // W2 死区:  Σ=640, 现为 0 → 保持 0
    win(8'sd80, 1'b1);   // W3 越阈:  Σ=1280 ≥ TH_ON → 1
    win(8'sd40, 1'b1);   // W4 死区:  Σ=640, 现为 1 → 保持 1
    win(8'sd8,  1'b0);   // W5 回落:  Σ=128  ≤ TH_OFF → 0
    win(-8'sd80,1'b1);   // W6 负样本: |din|=80 → Σ=1280 → 1
    win(8'sd8,  1'b0);   // W7 回落

    // W8 off-by-one: 前 15 个 68 (acc=1020 < TH_ON)，最后一个 8 → 1028 ≥ TH_ON
    for (k = 0; k < W - 1; k = k + 1) send(8'sd68, 1'b1);
    send(8'sd8, 1'b1);
    if (active !== 1'b1) begin
      $display("FAIL off-by-one @%0t: active=%0b (expect 1) —— 窗和漏算了最后一个样本?",
               $time, active);
      err = err + 1;
    end
    cur_active = 1'b1;
    win(8'sd8, 1'b0);    // W9 回落

    // W10 din_valid 门控: 5有效 + 3无效(大数) + 11有效 → 只算 16 个有效 → Σ=1280 → 1
    for (k = 0; k < 5;  k = k + 1) send(8'sd80,  1'b1);
    for (k = 0; k < 3;  k = k + 1) send(8'sd127, 1'b0);   // valid=0，不该计数
    for (k = 0; k < 11; k = k + 1) send(8'sd80,  1'b1);
    if (active !== 1'b1) begin
      $display("FAIL valid-gating @%0t: active=%0b (expect 1) —— 无效样本被算进窗和了?",
               $time, active);
      err = err + 1;
    end
    cur_active = 1'b1;
    win(8'sd8, 1'b0);    // W11 收尾回落

    if (err == 0) $display(">>> tb_activity_detector PASS (W=%0d TH_ON=%0d TH_OFF=%0d 全对)",
                           W, TH_ON, TH_OFF);
    else          $display(">>> tb_activity_detector FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #200000 $display(">>> tb_activity_detector TIMEOUT"); $finish; end
endmodule
