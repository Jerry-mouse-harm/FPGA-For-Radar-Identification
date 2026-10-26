`timescale 1ns/1ns
// tb_readout: 读出层（FC2 + argmax）判分台（自动 PASS/FAIL）
//
// 金标准 tb/fc_spike_exp.hex / fc_class_exp.hex / fc_logits_exp.hex 由
// gen_fc_vectors.py 用整数模型算出。11 帧 × 16 步 × 32 路脉冲。
//
// 除结果外还检查：
//   1) frame_start 后累加器清零；每个 in_valid 后 busy 必须拉高
//   2) 每个时间步的 32 拍累加必须在上限内完成（死锁检测）
//   3) 每帧 done 恰好 1 拍；done 同拍 class/logits_out 有效、busy=0
//   4) 帧之间不复位也能连续跑
//
// logits 打包：{cand[4], cand[3], cand[2], cand[1], cand[0]}，每段 20 bit 有符号。
module tb_readout;
  localparam NR = 32;
  localparam NC = 5;
  localparam T  = 16;
  localparam LW = 20;
  localparam NF = 11;
  localparam MAX_STEP = 100;        // 每步 32 拍 + 余量

  reg clk = 0, rst_n = 0, frame_start = 0, in_valid = 0;
  reg [NR-1:0] in_spike = 0;
  wire busy, done;
  wire [2:0] cls;
  wire signed [NC*LW-1:0] logits_out;

  reg [NR-1:0]        spk_mem  [0:NF*T-1];
  reg [3:0]           cls_mem  [0:NF-1];
  reg [NC*LW-1:0]     log_mem  [0:NF-1];

  integer err = 0, chk = 0, shown = 0;
  integer f, t, cyc, c;
  reg [LW-1:0] got_l, exp_l;

  readout #(
    .NR(NR), .NC(NC), .T(T), .LW(LW), .TW(16)
  ) u_dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .frame_start(frame_start),
    .in_valid   (in_valid),
    .in_spike   (in_spike),
    .busy       (busy),
    .done       (done),
    .cls        (cls),
    .logits_out (logits_out)
  );

  always #5 clk = ~clk;

  initial begin
    $dumpfile("logs/tb_readout.vcd");
    $dumpvars(1, tb_readout);
    $dumpvars(0, u_dut);

    $readmemh("tb/fc_spike_exp.hex", spk_mem);
    $readmemh("tb/fc_class_exp.hex", cls_mem);
    $readmemh("tb/fc_logits_exp.hex", log_mem);
    if ((^spk_mem[0]) === 1'bx || (^log_mem[0]) === 1'bx) begin
      $display(">>> tb_readout FAIL: tb/*.hex 未加载（先 make fc_weights / fc_vectors）");
      $finish;
    end

    // ------------------------------------------------------------------
    // 复位期间输出必须全 0
    // ------------------------------------------------------------------
    repeat (3) @(posedge clk); #1;
    chk = chk + 1;
    if (busy !== 0 || done !== 0 || cls !== 0 || logits_out !== 0) begin
      err = err + 1;
      $display("FAIL reset @%0t: busy=%b done=%b cls=%0d logits=%h",
               $time, busy, done, cls, logits_out);
    end
    @(negedge clk) rst_n = 1'b1;

    // ------------------------------------------------------------------
    // 逐帧
    // ------------------------------------------------------------------
    for (f = 0; f < NF; f = f + 1) begin
      // 新帧清零
      @(negedge clk) frame_start = 1'b1;
      @(negedge clk) frame_start = 1'b0;

      // ---- 16 个时间步，每步喂 32-bit 脉冲 ----
      for (t = 0; t < T; t = t + 1) begin
        @(negedge clk);
        in_spike = spk_mem[f*T + t];
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;

        chk = chk + 1;
        if (busy !== 1) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL frame%0d t%0d: in_valid 后 busy 未拉高 @%0t",
                     f, t, $time);
          end
        end

        // 等这一时间步的 32 路扫完
        cyc = 0;
        while (busy && cyc < MAX_STEP) begin
          @(posedge clk); #1;
          cyc = cyc + 1;
          chk = chk + 1;
          if (done !== 0 && t != T-1) begin
            err = err + 1;
            $display("FAIL frame%0d t%0d: 非最后一步就出现 done @%0t", f, t, $time);
          end
        end
        if (cyc >= MAX_STEP) begin
          err = err + 1;
          $display("FAIL frame%0d t%0d: 32 拍累加未完成（死锁）", f, t);
        end
      end

      // ---- 等 done，检查结果 ----
      cyc = 0;
      while (!done && cyc < MAX_STEP) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
      end

      chk = chk + 1;
      if (!done) begin
        err = err + 1;
        $display("FAIL frame%0d: 没有 done（死锁）", f);
      end
      chk = chk + 1;
      if (busy !== 0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 同拍 busy 应为 0 @%0t", f, $time);
      end
      chk = chk + 1;
      if (cls !== cls_mem[f]) begin
        err = err + 1;
        $display("FAIL frame%0d: class=%0d expect %0d",
                 f, cls, cls_mem[f]);
      end

      for (c = 0; c < NC; c = c + 1) begin
        chk = chk + 1;
        got_l = logits_out[c*LW +: LW];
        exp_l = log_mem[f][c*LW +: LW];
        if (got_l !== exp_l) begin
          err = err + 1;
          if (shown < 12) begin
            shown = shown + 1;
            $display("FAIL frame%0d logit[%0d]: got %h expect %h",
                     f, c, got_l, exp_l);
          end
        end
      end

      // ---- done 必须是单拍 ----
      @(posedge clk); #1;
      chk = chk + 1;
      if (done !== 0 || busy !== 0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 后一拍 done/busy = %b/%b", f, done, busy);
      end
    end

    // ------------------------------------------------------------------
    if (err == 0)
      $display(">>> tb_readout PASS (%0d checks: %0d 帧 x %0d 步 x %0d 神经元)",
               chk, NF, T, NR);
    else
      $display(">>> tb_readout FAIL (err=%0d / %0d checks)", err, chk);
    $finish;
  end

  initial begin
    #500000;
    $display(">>> tb_readout TIMEOUT");
    $finish;
  end
endmodule
