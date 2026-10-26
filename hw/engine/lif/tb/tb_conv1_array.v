`timescale 1ns/1ns
// tb_conv1_array: Conv1 阵列判分台（自动 PASS/FAIL）
//
// 金标准 tb/conv1_in.hex / tb/conv1_spike_exp.hex 由 gen_conv1_vectors.py
// 按 gen_conv1_weights.py 生成的同一组权重、用整数模型算出。
// 10 帧 × 8 通道 × 16 步 × 128 位置，全向量逐位对拍。
//
// 除向量外还检查：
//   1) 装载期间绝不允许有 out_valid/done；第一个 in_valid 后 busy 必须拉高
//   2) 输出顺序必须是 ch=0..7、每通道 t=0..15（用 out_ch/out_step 标签查）
//   3) 每个 (ch,step) 恰好出现一次，不能重复/缺失
//   4) done 与最后一个 out_valid 同拍；done 后的下一拍 busy/done/out_valid 全落
//   5) 帧之间不复位也能连续跑（模块自己回 IDLE）
//
// 单帧周期预算 MAX_CYCLES：设计值约 2736（16 装载 + 8×(4×81+16)），留到 3600 抓死锁。
module tb_conv1_array;
  localparam N  = 128;
  localparam T  = 16;
  localparam C  = 8;
  localparam PW = 16;
  localparam NF = 10;
  localparam MAX_CYCLES = 8000;

  reg clk = 0, rst_n = 0, in_valid = 0;
  reg [N-1:0] in_spike = 0;
  wire busy, done, out_valid;
  wire [2:0] out_ch;
  wire [3:0] out_step;
  wire [N-1:0] out_spike;

  reg [N-1:0] in_mem  [0:NF*T-1];
  reg [N-1:0] exp_mem [0:NF*C*T-1];
  reg [N-1:0] got     [0:C*T-1];

  integer err = 0, chk = 0, shown = 0;
  integer f, t, idx, cyc, out_cnt, exp_ch, exp_step;
  reg [C*T-1:0] seen;

  conv1_array #(
    .N(N), .T(T), .C(C), .K(5), .PW(PW),
    .VW(16), .XW(16), .TW(16)
  ) u_dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .in_spike  (in_spike),
    .busy      (busy),
    .done      (done),
    .out_valid (out_valid),
    .out_ch    (out_ch),
    .out_step  (out_step),
    .out_spike (out_spike)
  );

  always #5 clk = ~clk;

  initial begin
    $dumpfile("logs/tb_conv1_array.vcd");
    $dumpvars(1, tb_conv1_array);
    $dumpvars(0, u_dut.state, u_dut.busy, u_dut.done, u_dut.out_valid,
                 u_dut.ch_q, u_dut.g_q, u_dut.step_q, u_dut.tap_q);

    $readmemh("tb/conv1_in.hex", in_mem);
    $readmemh("tb/conv1_spike_exp.hex", exp_mem);
    if ((^in_mem[0]) === 1'bx || (^exp_mem[0]) === 1'bx) begin
      $display(">>> tb_conv1_array FAIL: tb/*.hex 未加载（先 make weights / vectors）");
      $finish;
    end

    // ------------------------------------------------------------------
    // 复位期间输出必须全 0
    // ------------------------------------------------------------------
    repeat (3) @(posedge clk); #1;
    chk = chk + 1;
    if (busy !== 0 || done !== 0 || out_valid !== 0 || out_spike !== 0) begin
      err = err + 1;
      $display("FAIL reset @%0t: busy=%b done=%b ov=%b spike=%h",
               $time, busy, done, out_valid, out_spike);
    end
    @(negedge clk) rst_n = 1'b1;

    // ------------------------------------------------------------------
    // 逐帧
    // ------------------------------------------------------------------
    for (f = 0; f < NF; f = f + 1) begin
      out_cnt = 0;
      seen    = {C*T{1'b0}};

      // ---- 装载 16 个步向量 ----
      for (t = 0; t < T; t = t + 1) begin
        @(negedge clk);
        in_spike  = in_mem[f*T + t];
        in_valid  = 1'b1;
        @(posedge clk); #1;
        chk = chk + 1;
        if (out_valid !== 0 || done !== 0) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL frame%0d load t=%0d @%0t: out_valid=%b done=%b (应该还没输出)",
                     f, t, $time, out_valid, done);
          end
        end
        if (t == 0 && busy !== 1) begin
          err = err + 1;
          $display("FAIL frame%0d: 首个 in_valid 后 busy 未拉高 @%0t", f, $time);
        end
      end
      @(negedge clk) in_valid = 1'b0;

      if (busy !== 1) begin
        err = err + 1;
        $display("FAIL frame%0d: 装载完成后 busy 应为 1 @%0t", f, $time);
      end

      // ---- 等 done，边收边查顺序 ----
      cyc = 0;
      while (!done && cyc < MAX_CYCLES) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
        if (out_valid) begin
          idx      = out_ch * T + out_step;
          exp_ch   = out_cnt / T;
          exp_step = out_cnt % T;

          if (out_ch !== exp_ch || out_step !== exp_step) begin
            err = err + 1;
            if (shown < 12) begin
              shown = shown + 1;
              $display("FAIL frame%0d out%0d: 标签 ch=%0d step=%0d (expect %0d/%0d)",
                       f, out_cnt, out_ch, out_step, exp_ch, exp_step);
            end
          end
          if (seen[idx]) begin
            err = err + 1;
            if (shown < 12) begin
              shown = shown + 1;
              $display("FAIL frame%0d: (ch=%0d,step=%0d) 重复输出", f, out_ch, out_step);
            end
          end

          seen[idx] = 1'b1;
          got[idx]  = out_spike;
          out_cnt   = out_cnt + 1;
        end
      end

      // ---- 帧级结构检查 ----
      chk = chk + 1;
      if (!done) begin
        err = err + 1;
        $display("FAIL frame%0d: %0d 拍内没有 done（死锁）", f, MAX_CYCLES);
      end
      chk = chk + 1;
      if (out_cnt !== C*T) begin
        err = err + 1;
        $display("FAIL frame%0d: 输出拍数 %0d（expect %0d）", f, out_cnt, C*T);
      end
      chk = chk + 1;
      if (seen !== {C*T{1'b1}}) begin
        err = err + 1;
        $display("FAIL frame%0d: 输出标签有缺失/重复（seen=%h）", f, seen);
      end
      chk = chk + 1;
      if (busy !== 0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 同拍 busy 应为 0 @%0t", f, $time);
      end

      // ---- 逐位对拍 ----
      for (idx = 0; idx < C*T; idx = idx + 1) begin
        chk = chk + 1;
        if (got[idx] !== exp_mem[f*C*T + idx]) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL frame%0d ch%0d step%0d: got %h expect %h",
                     f, idx/T, idx%T, got[idx], exp_mem[f*C*T + idx]);
          end
        end
      end

      // ---- done 必须是单拍，下一拍接口全落 ----
      @(posedge clk); #1;
      chk = chk + 1;
      if (done !== 0 || out_valid !== 0 || busy !== 0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 后一拍 busy/done/out_valid = %b/%b/%b",
                 f, busy, done, out_valid);
      end
    end

    // ------------------------------------------------------------------
    if (err == 0)
      $display(">>> tb_conv1_array PASS (%0d checks: %0d 帧 x %0d 通道 x %0d 步 x 128 位置)",
               chk, NF, C, T);
    else
      $display(">>> tb_conv1_array FAIL (err=%0d / %0d checks)", err, chk);
    $finish;
  end

  initial begin
    #3000000;
    $display(">>> tb_conv1_array TIMEOUT");
    $finish;
  end
endmodule
