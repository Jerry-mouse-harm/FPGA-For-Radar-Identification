// tb_engine_demo.v —— 上板前验接线：真实引擎 + 样本 ROM + 自动起帧 + LED 编码
//
// 检查项：
//   1. 每次 eng_done 后，LED[2:0] 反码 = 该帧期望类别（9 帧循环，跑 12 帧验证回卷）
//   2. 每帧 busy 持续拍数在合理范围（≈158791 @ PW1=PW2=8/LP=4）
//   3. done 时 busy 已落、帧计数器按 0..8 正确推进并回卷
//   4. 12 帧内无超时
//
// 用法（hw/board 下）：
//   iverilog -g2012 -o engine_demo/tb_engine_demo.out engine_demo/tb_engine_demo.v ...
module tb_engine_demo;

  reg clk = 1'b0;
  always #10 clk = ~clk;                 // 50MHz 仿真（时序无关，跑快点）

  wire [5:0] leds;

  top #(.GAP_BITS(4)) dut (
    .clk  (clk),
    .leds (leds)
  );

  localparam integer NF  = 12;           // 跑 12 帧，验证 9 帧回卷
  localparam integer NFR = 9;            // ROM 里 9 帧

  reg [2:0] exp_cls [0:NFR-1];
  initial begin
    exp_cls[0] = 3'd0;
    exp_cls[1] = 3'd4;
    exp_cls[2] = 3'd4;
    exp_cls[3] = 3'd4;
    exp_cls[4] = 3'd4;
    exp_cls[5] = 3'd4;
    exp_cls[6] = 3'd0;
    exp_cls[7] = 3'd3;
    exp_cls[8] = 3'd0;
  end

  integer errors    = 0;
  integer done_cnt  = 0;
  integer busy_cnt  = 0;
  integer last_busy = 0;

  // busy 拍数统计
  always @(posedge clk)
    if (dut.eng_busy) busy_cnt = busy_cnt + 1;

  reg [2:0] cls;
  integer   dur;

  always @(negedge clk) begin
    if (dut.eng_done) begin
      cls = ~leds[2:0];                  // 低电平点亮，反码才是类别
      dur = busy_cnt - last_busy;
      last_busy = busy_cnt;

      $display("[frame %0d] class=%0d (exp %0d) busy=%0d cycles leds=%b",
               done_cnt, cls, exp_cls[done_cnt % NFR], dur, leds);

      if (cls !== exp_cls[done_cnt % NFR]) begin
        $display("  ERROR: class mismatch");
        errors = errors + 1;
      end
      if (dur < 100000 || dur > 200000) begin
        $display("  ERROR: busy duration out of range");
        errors = errors + 1;
      end
      if (leds[4] !== 1'b1) begin        // done 时 busy 必须已落
        $display("  ERROR: busy still high at done");
        errors = errors + 1;
      end
      // 当前 done 对应第 done_cnt 帧（计数器在下一拍才推进，9 帧回卷）
      if (dut.frame_idx !== (done_cnt % NFR)) begin
        $display("  ERROR: frame_idx=%0d, expect %0d", dut.frame_idx, done_cnt % NFR);
        errors = errors + 1;
      end

      done_cnt = done_cnt + 1;
      if (done_cnt == NF) begin
        if (errors == 0)
          $display("TB_ENGINE_DEMO: PASS (%0d frames)", NF);
        else
          $display("TB_ENGINE_DEMO: FAIL, %0d errors", errors);
        $finish;
      end
    end
  end

  // 超时保护：每帧 ≈16 万拍，12 帧留足余量
  initial begin
    #(NF * 300000 * 20 + 1000000);
    $display("TB_ENGINE_DEMO: TIMEOUT after %0d frames", done_cnt);
    $finish;
  end

endmodule
