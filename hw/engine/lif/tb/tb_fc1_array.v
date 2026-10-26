`timescale 1ns/1ns
// tb_fc1_array: FC1 阵列判分台（自动 PASS/FAIL）
//
// 金标准 tb/fc_in.hex / tb/fc_spike_exp.hex 由 gen_fc_vectors.py 按
// gen_fc1_weights.py 生成的同一组权重、用整数模型算出。
// 11 帧 × 16 时间步 × 32 神经元，逐位对拍。
//
// 输入流与 Conv2 输出完全一致：每帧 16 输入通道 × 16 步，共 256 拍，
// 每拍带 in_ch / in_step 标签（DUT 内部按标签写缓存）。
//
// 除向量外还检查：
//   1) 装载期间绝不允许有 spk_valid/frame_done；第一个 in_valid 后 busy 必须拉高
//   2) 每帧 frame_start 恰好 1 拍
//   3) spk_valid 恰好 T 拍，按时间步 0..15 顺序给出
//   4) frame_done 与第 T 个 spk_valid 同拍；done 后一拍 busy/spk_valid/frame_done 全落
//   5) 帧之间不复位也能连续跑（模块自己回 IDLE）
//
// 单帧周期预算：256 装载 + T×NG×(1 + 512 + 1)，按时限留余量抓死锁。
// LP=8（NG=4）时单帧 ≈ 33k 拍。
module tb_fc1_array;
  localparam NPIN = 64;
  localparam CI   = 16;
  localparam T    = 16;
  localparam NR   = 32;
  localparam NF   = 11;
  localparam LP   = 8;                       // 与 DUT 默认一致：并行 lane 数
  localparam NG   = NR / LP;                 // 每个时间步扫几趟
  localparam MAX_CYCLES = 256 + T * (NG * (2 + CI * 32) + 2) + 4000;

  reg clk = 0, rst_n = 0, in_valid = 0;
  reg [3:0]  in_ch = 0;
  reg [3:0]  in_step = 0;
  reg [NPIN-1:0] in_spike = 0;
  wire busy, frame_start, spk_valid, frame_done;
  wire [NR-1:0] spk_vec;

  reg [NPIN-1:0] in_mem  [0:NF*CI*T-1];
  reg [NR-1:0]   exp_mem [0:NF*T-1];
  reg [NR-1:0]   got     [0:T-1];

  integer err = 0, chk = 0, shown = 0;
  integer f, i, t, idx, cyc, spk_cnt, fs_cnt, f_err, f_shown;

  fc1_array #(
    .NPIN(NPIN), .NP(32), .CI(CI), .T(T), .NR(NR), .LP(LP),
    .VW(16), .XW(16), .TW(16)
  ) u_dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .in_ch      (in_ch),
    .in_step    (in_step),
    .in_spike   (in_spike),
    .busy       (busy),
    .frame_start(frame_start),
    .spk_valid  (spk_valid),
    .spk_vec    (spk_vec),
    .frame_done (frame_done)
  );

  always #5 clk = ~clk;

  initial begin
    $dumpfile("logs/tb_fc1_array.vcd");
    $dumpvars(1, tb_fc1_array);
    $dumpvars(0, u_dut.state, u_dut.busy, u_dut.frame_start, u_dut.spk_valid,
                 u_dut.frame_done, u_dut.step_q, u_dut.c_q,
                 u_dut.ld_cnt, u_dut.rd_addr, u_dut.w_addr);

    $readmemh("tb/fc_in.hex", in_mem);
    $readmemh("tb/fc_spike_exp.hex", exp_mem);
    if ((^in_mem[0]) === 1'bx || (^exp_mem[0]) === 1'bx) begin
      $display(">>> tb_fc1_array FAIL: tb/*.hex 未加载（先 make fc_weights / fc_vectors）");
      $finish;
    end

    // ------------------------------------------------------------------
    // 复位期间输出必须全 0
    // ------------------------------------------------------------------
    repeat (3) @(posedge clk); #1;
    chk = chk + 1;
    if (busy !== 0 || frame_start !== 0 || spk_valid !== 0 ||
        frame_done !== 0 || spk_vec !== 0) begin
      err = err + 1;
      $display("FAIL reset @%0t: busy=%b fs=%b sv=%b fd=%b vec=%h",
               $time, busy, frame_start, spk_valid, frame_done, spk_vec);
    end
    @(negedge clk) rst_n = 1'b1;

    // ------------------------------------------------------------------
    // 逐帧
    // ------------------------------------------------------------------
    for (f = 0; f < NF; f = f + 1) begin
      spk_cnt = 0;
      fs_cnt  = 0;

      // ---- 装载 CI*T 个 (通道,步) 向量 ----
      for (i = 0; i < CI*T; i = i + 1) begin
        @(negedge clk);
        in_spike = in_mem[f*CI*T + i];
        in_ch    = i / T;
        in_step  = i % T;
        in_valid = 1'b1;
        @(posedge clk); #1;
        chk = chk + 1;
        if (spk_valid !== 0 || frame_done !== 0 || frame_start !== 0) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL frame%0d load i=%0d @%0t: sv=%b fd=%b fs=%b（应该还没输出）",
                     f, i, $time, spk_valid, frame_done, frame_start);
          end
        end
        if (i == 0 && busy !== 1) begin
          err = err + 1;
          $display("FAIL frame%0d: 首个 in_valid 后 busy 未拉高 @%0t", f, $time);
        end
      end
      @(negedge clk) in_valid = 1'b0;

      if (busy !== 1) begin
        err = err + 1;
        $display("FAIL frame%0d: 装载完成后 busy 应为 1 @%0t", f, $time);
      end

      // ---- 等 frame_done，边收 spk_valid ----
      cyc = 0;
      while (!frame_done && cyc < MAX_CYCLES) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
        if (frame_start) fs_cnt = fs_cnt + 1;
        if (spk_valid) begin
          if (spk_cnt < T) got[spk_cnt] = spk_vec;
          spk_cnt = spk_cnt + 1;
        end
      end

      // ---- 帧级结构检查 ----
      chk = chk + 1;
      if (!frame_done) begin
        err = err + 1;
        $display("FAIL frame%0d: %0d 拍内没有 frame_done（死锁）", f, MAX_CYCLES);
      end
      chk = chk + 1;
      if (spk_cnt !== T) begin
        err = err + 1;
        $display("FAIL frame%0d: spk_valid 拍数 %0d（expect %0d）", f, spk_cnt, T);
      end
      chk = chk + 1;
      if (fs_cnt !== 1) begin
        err = err + 1;
        $display("FAIL frame%0d: frame_start 出现 %0d 次（expect 1）", f, fs_cnt);
      end
      chk = chk + 1;
      if (busy !== 0) begin
        err = err + 1;
        $display("FAIL frame%0d: frame_done 同拍 busy 应为 0 @%0t", f, $time);
      end

      // ---- 逐位对拍（每帧最多打印 4 条，帧尾汇总失配步数）----
      f_shown = 0;
      f_err   = 0;
      for (t = 0; t < T; t = t + 1) begin
        chk = chk + 1;
        if (got[t] !== exp_mem[f*T + t]) begin
          err = err + 1;
          f_err = f_err + 1;
          if (f_shown < 4) begin
            f_shown = f_shown + 1;
            $display("FAIL frame%0d t%0d: got %h expect %h",
                     f, t, got[t], exp_mem[f*T + t]);
          end
        end
      end
      if (f_err != 0)
        $display("FAIL frame%0d: %0d/%0d 步失配", f, f_err, T);

      // ---- frame_done 必须是单拍，下一拍接口全落 ----
      @(posedge clk); #1;
      chk = chk + 1;
      if (frame_done !== 0 || spk_valid !== 0 || busy !== 0 || frame_start !== 0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 后一拍 busy/sv/fd/fs = %b/%b/%b/%b",
                 f, busy, spk_valid, frame_done, frame_start);
      end
    end

    // ------------------------------------------------------------------
    if (err == 0)
      $display(">>> tb_fc1_array PASS (%0d checks: %0d 帧 x %0d 步 x %0d 神经元)",
               chk, NF, T, NR);
    else
      $display(">>> tb_fc1_array FAIL (err=%0d / %0d checks)", err, chk);
    $finish;
  end

  initial begin
    #(NF * (MAX_CYCLES + 600) * 10);   // 全局看门狗也随 NG 放宽
    $display(">>> tb_fc1_array TIMEOUT");
    $finish;
  end
endmodule
