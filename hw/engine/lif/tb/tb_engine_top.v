`timescale 1ns/1ns
// tb_engine_top: 识别引擎顶层端到端判分台（自动 PASS/FAIL）
//
// 判什么：
//   · 9 帧 din 样本（全零/满量程/交替/斜坡/随机 + 3 类真实形状）
//   · 每帧：eng_start → encode_frontend → Conv1 → Conv2 → FC1 → readout
//   · 逐帧对拍类别（eng_class）与 logits（readout.logits_out）
//   · 握手：eng_busy 从 start 后一直为 1 到出结果；eng_done 单拍；
//           done 后一拍 done 落、class 保持；连续多帧不用中间复位
//   · 帧中途插一个假 eng_start，FSM 必须忽略（不能多跑一帧 / 多一个 done）
//
// 模型假设：
//   · 样本 BRAM 是同步读：smp_addr 发出后，smp_data 在**下一拍**有效
//   · 单帧周期上限 MAX_CYCLES（正常约 80k 拍 @PW=16/LP=8），超时判死锁
//
// 金标准 tb/engine_smp.hex / engine_cls_exp.hex / engine_logits_exp.hex
// 由 gen_engine_vectors.py 用同一组权重、按整数模型算出。
module tb_engine_top;

  localparam N  = 128;
  localparam T  = 16;
  localparam AW = 7;
  localparam NF = 9;                 // 与 gen_engine_vectors.py 的帧数一致
  localparam LW = 20;

  // 并行度可由 Makefile 用 -DENG_PW1/-DENG_PW2/-DENG_LP 覆盖；
  // 默认 = 功能仿真配置。算术结果与并行度无关。
`ifndef ENG_PW1
  `define ENG_PW1 16
`endif
`ifndef ENG_PW2
  `define ENG_PW2 16
`endif
`ifndef ENG_LP
  `define ENG_LP 8
`endif
  localparam PW1 = `ENG_PW1;
  localparam PW2 = `ENG_PW2;
  localparam LP  = `ENG_LP;
  localparam MAX_CYCLES = 260000;    // 单帧看门狗（默认 ≈80k，LP=4 ≈113k）

  reg  clk = 0;
  reg  rst_n = 0;
  reg  eng_start = 0;

  wire              eng_busy;
  wire              eng_done;
  wire [2:0]        eng_class;
  wire [AW-1:0]     smp_addr;
  wire signed [7:0] smp_data;

  // ---------------- DUT ----------------
  engine_top #(
    .N   (N),
    .T   (T),
    .AW  (AW),
    .PW1 (PW1),
    .PW2 (PW2),
    .LP  (LP)
  ) u_dut (
    .clk_eng   (clk),
    .eng_rst_n (rst_n),
    .eng_start (eng_start),
    .eng_busy  (eng_busy),
    .eng_done  (eng_done),
    .eng_class (eng_class),
    .smp_addr  (smp_addr),
    .smp_data  (smp_data)
  );

  // ---------------- 同步读 BRAM 模型（地址后 1 拍出数据）----------------
  reg signed [7:0] smp_rom [0:N-1];
  reg signed [7:0] smp_q;
  assign smp_data = smp_q;
  always @(posedge clk) smp_q <= smp_rom[smp_addr];

  // 顶层没引出 logits，判分台直接看 readout 的输出寄存器（done 拍有效）
  wire [5*LW-1:0] dut_logits = u_dut.u_readout.logits_out;

  // ---------------- 金标准 ----------------
  reg signed [7:0] smp_mem [0:NF*N-1];      // 帧 f 样本 i 在 f*N+i
  reg [3:0]        cls_exp [0:NF-1];
  reg [5*LW-1:0]   logits_exp [0:NF-1];     // c=0 在最低 20 位

  integer err = 0, chk = 0;
  integer f, i, cyc, busy_drop, shown;

  always #5 clk = ~clk;

  initial begin
`ifndef ENG_NODUMP
    $dumpfile("logs/tb_engine_top.vcd");
    $dumpvars(0, tb_engine_top);
`endif

    $readmemh("tb/engine_smp.hex", smp_mem);
    $readmemh("tb/engine_cls_exp.hex", cls_exp);
    $readmemh("tb/engine_logits_exp.hex", logits_exp);

    if ((^smp_mem[0]) === 1'bx || (^cls_exp[0]) === 1'bx ||
        (^logits_exp[0]) === 1'bx) begin
      $display(">>> tb_engine_top FAIL: tb/engine_*.hex 未加载（先 make engine_vectors）");
      $finish;
    end

    // ------------------------------------------------------------------
    // 复位期间输出必须全 0
    // ------------------------------------------------------------------
    repeat (3) @(posedge clk); #1;
    chk = chk + 1;
    if (eng_busy !== 0 || eng_done !== 0 || eng_class !== 0) begin
      err = err + 1;
      $display("FAIL reset @%0t: busy=%b done=%b class=%0d",
               $time, eng_busy, eng_done, eng_class);
    end
    @(negedge clk) rst_n = 1'b1;

    // ------------------------------------------------------------------
    // 逐帧
    // ------------------------------------------------------------------
    for (f = 0; f < NF; f = f + 1) begin
      // 避开采样沿把本帧样本装进 ROM 模型
      @(negedge clk);
      for (i = 0; i < N; i = i + 1) smp_rom[i] = smp_mem[f*N + i];

      eng_start = 1'b1;
      @(negedge clk);
      eng_start = 1'b0;

      // start 被采样后 busy 应立刻起来
      @(posedge clk); #1;
      chk = chk + 1;
      if (eng_busy !== 1'b1) begin
        err = err + 1;
        $display("FAIL frame%0d: start 后 busy=%b（expect 1）", f, eng_busy);
      end

      // ---- 等 done，期间 busy 不能掉 ----
      busy_drop = 0;
      cyc = 0;
      while (eng_done !== 1'b1 && cyc < MAX_CYCLES) begin
        // 第 4 帧工作途中插一个假 start（FSM 在 S_RUN 应忽略）
        if (f == 4 && cyc == 5000) begin
          @(negedge clk) eng_start = 1'b1;
          @(negedge clk) eng_start = 1'b0;
        end

        @(posedge clk); #1;
        cyc = cyc + 1;

        if (eng_done !== 1'b1 && eng_busy !== 1'b1)
          busy_drop = busy_drop + 1;
      end

      // ---- 帧级结构检查 ----
      chk = chk + 1;
      if (eng_done !== 1'b1) begin
        err = err + 1;
        $display("FAIL frame%0d: %0d 拍内没有 eng_done（死锁）", f, MAX_CYCLES);
      end

      chk = chk + 1;
      if (busy_drop != 0) begin
        err = err + 1;
        $display("FAIL frame%0d: 出结果前 eng_busy 掉了 %0d 拍", f, busy_drop);
      end

      chk = chk + 1;
      if (eng_busy !== 1'b0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 拍 busy 应为 0（got %b）", f, eng_busy);
      end

      // ---- 类别 / logits 对拍 ----
      chk = chk + 1;
      if (eng_class !== cls_exp[f][2:0]) begin
        err = err + 1;
        $display("FAIL frame%0d class: got %0d expect %0d", f, eng_class, cls_exp[f][2:0]);
      end

      chk = chk + 1;
      if (dut_logits !== logits_exp[f]) begin
        err = err + 1;
        if (shown < 8) begin
          shown = shown + 1;
          $display("FAIL frame%0d logits:\n  got    %025h\n  expect %025h",
                   f, dut_logits, logits_exp[f]);
        end
      end

      // ---- done 必须是单拍；class 保持到下一帧 ----
      @(posedge clk); #1;
      chk = chk + 1;
      if (eng_done !== 1'b0 || eng_busy !== 1'b0) begin
        err = err + 1;
        $display("FAIL frame%0d: done 后一拍 done/busy = %b/%b", f, eng_done, eng_busy);
      end
      chk = chk + 1;
      if (eng_class !== cls_exp[f][2:0]) begin
        err = err + 1;
        $display("FAIL frame%0d: done 后 class 没保持（got %0d）", f, eng_class);
      end

      $display("frame%0d: class=%0d logits=%h  cyc=%0d", f, eng_class, dut_logits, cyc);
    end

    // ------------------------------------------------------------------
    if (err == 0)
      $display(">>> tb_engine_top PASS (%0d checks: %0d 帧端到端 class+logits)", chk, NF);
    else
      $display(">>> tb_engine_top FAIL (err=%0d / %0d checks)", err, chk);
    $finish;
  end

  initial begin
    #(NF * (MAX_CYCLES + 3000) * 10);
    $display(">>> tb_engine_top TIMEOUT");
    $finish;
  end

endmodule
