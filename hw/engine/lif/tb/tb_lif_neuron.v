`timescale 1ns/1ns
// tb_lif_neuron: LIF 神经元判分台（自动 PASS/FAIL）
//
// 金标准 tb/{th,x,spike_exp,v_exp}.hex 由 tb/gen_lif_vectors.py 用整数模型生成。
// 24 个用例 × 16 步，覆盖：
//   阈值边界（>= 不是 > / off-by-one）、慢积分、单步多发、正负混合、无泄漏、
//   双向饱和、阈值上限"撞线 / 差一点"、阈值 1、大幅摆动、4 个随机序列。
//
// 另有 3 项结构检查（向量管不到的部分）：
//   1) 异步复位立即生效（不等时钟沿）
//   2) step_valid=0 时 v_out / spike 完全冻结（纯 IF，空闲不改变状态）
//   3) reset 释放后的第一拍输出必须是 0（不能残留上一个用例的状态）
//
// 时序约定（与 rtl/lif_neuron.v 头注释一致）：
//   负沿改激励 → 正沿采样更新 → #1 后检查寄存器输出。
//
// 若 tb/*.hex 不存在：先跑 `make -C hw/engine/lif vectors`。
module tb_lif_neuron;
  localparam NC = 24;
  localparam T  = 16;
  localparam VW = 16;
  localparam XW = 16;
  localparam TW = 16;

  reg clk = 0, rst_n = 0, step_valid = 0;
  reg signed [XW-1:0] x_in = 0;
  reg signed [TW-1:0] th   = 0;
  wire                 spike;
  wire signed [VW-1:0] v_out;

  integer err = 0, chk = 0, shown = 0;
  integer i, t, k, idx;
  reg [7:0] exp_s;

  reg [TW-1:0] th_mem  [0:NC-1];
  reg [XW-1:0] x_mem   [0:NC*T-1];
  reg [7:0]    spk_mem [0:NC*T-1];
  reg [VW-1:0] v_mem   [0:NC*T-1];

  lif_neuron #(.VW(VW), .XW(XW), .TW(TW)) u_dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .step_valid(step_valid),
    .x_in      (x_in),
    .th        (th),
    .spike     (spike),
    .v_out     (v_out)
  );

  always #5 clk = ~clk;

  initial begin
    $dumpfile("logs/tb_lif_neuron.vcd");
    $dumpvars(0, tb_lif_neuron);

    $readmemh("tb/th.hex",        th_mem);
    $readmemh("tb/x.hex",         x_mem);
    $readmemh("tb/spike_exp.hex", spk_mem);
    $readmemh("tb/v_exp.hex",     v_mem);

    // 四个文件任何一个没加载都会在全 x 上暴露
    if ((^th_mem[0]) === 1'bx || (^x_mem[0]) === 1'bx ||
        (^spk_mem[0]) === 1'bx || (^v_mem[0]) === 1'bx) begin
      $display(">>> tb_lif_neuron FAIL: tb/*.hex 未加载（先 make vectors）");
      $finish;
    end

    // ------------------------------------------------------------------
    // 0) 复位期间输出必须为 0
    // ------------------------------------------------------------------
    rst_n = 0;
    repeat (3) @(posedge clk); #1;
    chk = chk + 1;
    if (v_out !== 0 || spike !== 0) begin
      err = err + 1;
      $display("FAIL reset @%0t: v=%0d spike=%0b (expect 0/0)",
               $time, v_out, spike);
    end

    // ------------------------------------------------------------------
    // 1) 24 个向量用例
    // ------------------------------------------------------------------
    for (i = 0; i < NC; i = i + 1) begin
      // 每个用例先异步复位、装阈值；复位释放后从第 0 步开始
      rst_n      = 1'b0;
      step_valid = 1'b0;
      x_in       = {XW{1'b0}};
      th         = th_mem[i];
      repeat (2) @(posedge clk);
      @(negedge clk) rst_n = 1'b1;

      for (t = 0; t < T; t = t + 1) begin
        idx = i*T + t;

        @(negedge clk);
        x_in       = x_mem[idx];
        step_valid = 1'b1;

        @(posedge clk); #1;
        chk = chk + 1;
        exp_s = spk_mem[idx];

        if (spike !== exp_s[0]) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL case%0d step%0d @%0t: spike=%0b (expect %0b)",
                     i, t, $time, spike, exp_s[0]);
          end
        end

        if (v_out !== v_mem[idx]) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL case%0d step%0d @%0t: v=%0d (expect %0d)",
                     i, t, $time, v_out, $signed(v_mem[idx]));
          end
        end
      end
    end

    // ------------------------------------------------------------------
    // 2) step_valid=0 必须完全冻结（纯 IF 没有泄漏）
    //    先走一步 x=150, th=100 → v=50, spike=1；随后空闲 4 拍，
    //    期间把 x_in 拉满正/负，v_out/spike 都不许动。
    // ------------------------------------------------------------------
    rst_n      = 1'b0;
    step_valid = 1'b0;
    x_in       = {XW{1'b0}};
    th         = 16'sd100;
    repeat (2) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;

    @(negedge clk); x_in = 16'sd150; step_valid = 1'b1;
    @(posedge clk); #1;
    chk = chk + 1;
    if (spike !== 1'b1 || v_out !== 16'sd50) begin
      err = err + 1;
      $display("FAIL hold setup @%0t: v=%0d spike=%0b (expect 50/1)",
               $time, v_out, spike);
    end

    step_valid = 1'b0;
    for (k = 0; k < 4; k = k + 1) begin
      @(negedge clk);
      x_in = k[0] ? 16'sh8000 : 16'sd32767;
      @(posedge clk); #1;
      chk = chk + 1;
      if (spike !== 1'b1 || v_out !== 16'sd50) begin
        err = err + 1;
        if (shown < 12) begin
          shown = shown + 1;
          $display("FAIL hold k=%0d @%0t: v=%0d spike=%0b (expect 50/1)",
                   k, $time, v_out, spike);
        end
      end
    end

    // 恢复：x=0 一步，v 仍 50 < 100 → 不发，spike 落 0
    @(negedge clk); x_in = 0; step_valid = 1'b1;
    @(posedge clk); #1;
    chk = chk + 1;
    if (spike !== 1'b0 || v_out !== 16'sd50) begin
      err = err + 1;
      $display("FAIL hold resume @%0t: v=%0d spike=%0b (expect 50/0)",
               $time, v_out, spike);
    end

    // ------------------------------------------------------------------
    // 3) 异步复位：拉低后不等时钟沿，v/spike 必须立即清零
    // ------------------------------------------------------------------
    @(negedge clk); x_in = 16'sd1000; step_valid = 1'b1;
    @(posedge clk); #1;                       // v = 50+1000 = 1050，仍不发
    rst_n = 1'b0; #2;                         // 正沿之后立刻复位（异步）
    chk = chk + 1;
    if (v_out !== 0 || spike !== 0) begin
      err = err + 1;
      $display("FAIL async reset @%0t: v=%0d spike=%0b (expect 0/0)",
               $time, v_out, spike);
    end
    rst_n = 1'b1; step_valid = 1'b0;

    // ------------------------------------------------------------------
    if (err == 0)
      $display(">>> tb_lif_neuron PASS (%0d checks: %0d 用例 x %0d 步 + 保持/异步复位)",
               chk, NC, T);
    else
      $display(">>> tb_lif_neuron FAIL (err=%0d / %0d checks)", err, chk);
    $finish;
  end

  initial begin
    #200000;
    $display(">>> tb_lif_neuron TIMEOUT");
    $finish;
  end
endmodule
