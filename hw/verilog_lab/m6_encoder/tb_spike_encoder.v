`timescale 1ns/1ns
// tb_spike_encoder: ΣΔ 脉冲序列判分台（自动 PASS/FAIL）
//
// 金标准 n_pattern.hex 由 gen_vectors.py 用项目编码器生成：
//   第 i 行 = 脉冲数 n=i 时那 16 步的发放图案，bit t = 第 t 步的 spike。
// n = 0..16 全枚举（17 个），任何"少发/多发/时序错位"都跑不掉。
// 自检锚点: n=0 → 全 0；n=8 → 隔一步发一次；n=16 → 全 1；n=1 的单个脉冲在**最后一步**。
//
// 复位释放时机很重要（我第一版就栽在这）：必须在"置 load"的**同一个负沿**上释放复位。
// 否则复位释放到 load 沿之间会多跑一个"影子步"，acc 被污染 → 同一个 bug 有时 PASS 有时 FAIL。
module tb_spike_encoder;
  localparam T  = 16;
  localparam NV = 17;

  reg clk = 0, rst_n = 0, load = 0;
  reg [4:0] n = 0;
  wire spike;
  integer err = 0;
  integer i, t;

  reg [15:0] pat [0:NV-1];
  reg [15:0] exp_pat;

  spike_encoder u_dut (.clk(clk), .rst_n(rst_n), .load(load), .n(n), .spike(spike));

  always #5 clk = ~clk;

  initial begin
    $dumpfile("tb_spike_encoder.vcd");
    $dumpvars(0, tb_spike_encoder);
    $readmemh("n_pattern.hex", pat);

    // 复位期间输出必须为 0
    rst_n = 0;
    repeat (3) @(posedge clk); #1;
    if (spike !== 1'b0) begin
      $display("FAIL reset @%0t: spike=%0b (expect 0)", $time, spike);
      err = err + 1;
    end

    @(negedge clk); rst_n = 1;          // 就在这个负沿释放, 下一个正沿才是模块看到的第一个沿

    for (i = 0; i < NV; i = i + 1) begin
      exp_pat = pat[i];

      load = 1'b1; n = i;                // 同一个负沿上置 load
      @(posedge clk); #1;                // ← load 被采样这一拍
      load = 1'b0;

      for (t = 0; t < T; t = t + 1) begin
        @(posedge clk); #1;              // 第 t 步
        if (spike !== exp_pat[t]) begin
          $display("FAIL n=%0d step%0d @%0t: spike=%0b (expect %0b)",
                   i, t, $time, spike, exp_pat[t]);
          err = err + 1;
        end
      end

      // T 步走完必须回 0, 而且不能残留
      repeat (2) begin
        @(posedge clk); #1;
        if (spike !== 1'b0) begin
          $display("FAIL n=%0d tail @%0t: spike=%0b (expect 0)", i, $time, spike);
          err = err + 1;
        end
      end
    end

    // ---- 收尾用例: 中途重载必须从头开始（load 要把 acc/step 一起清掉）----
    // 先载入 n=15 只走 3 步（此时 acc=13）就重载 n=4；acc 没清零的话新序列会错位。
    @(negedge clk); load = 1'b1; n = 15;
    @(posedge clk); #1;
    load = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk); load = 1'b1; n = 4;
    @(posedge clk); #1;
    load = 1'b0;
    exp_pat = pat[4];
    for (t = 0; t < T; t = t + 1) begin
      @(posedge clk); #1;
      if (spike !== exp_pat[t]) begin
        $display("FAIL reload n=4 step%0d @%0t: spike=%0b (expect %0b)",
                 t, $time, spike, exp_pat[t]);
        err = err + 1;
      end
    end

    if (err == 0) $display(">>> tb_spike_encoder PASS (n=0..%0d 全对 + 中途重载归零, T=%0d 步)", T, T);
    else          $display(">>> tb_spike_encoder FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #100000 $display(">>> tb_spike_encoder TIMEOUT"); $finish; end
endmodule
