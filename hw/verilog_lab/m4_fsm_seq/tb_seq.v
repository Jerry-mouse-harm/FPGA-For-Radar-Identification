`timescale 1ns/1ns
// tb_seq: 序列检测 1011（可重叠）判分台（自动 PASS/FAIL）
// 判据是一个独立的"滑窗子串"oracle：纯看输入比特流里有没有连续 1011，
// 与你的状态机实现无关 —— 所以它过 = 真对。
module tb_seq;
  reg clk = 0;
  reg rst_n = 0;
  reg din = 0;
  wire det;
  integer err = 0;

  seq_det u_dut (.clk(clk), .rst_n(rst_n), .din(din), .det(det));

  always #5 clk = ~clk;

  // ---- 输入序列：15 位 ----
  integer seq [0:14];
  integer exp [0:14];       // 期望 det 的位下标
  integer i, j;
  reg match;

  task check(input e_det, input integer step);
    begin
      if (det !== e_det) begin
        $display("FAIL step %0d @%0t: det=%0b (expect %0b)", step, $time, det, e_det);
        err = err + 1;
      end
    end
  endtask

  initial begin
    // 初始化序列与期望（oracle）
    // 序列: 1 0 1 1 0 1 1 0 0 0 0 1 0 1 1
    seq[0]=1; seq[1]=0; seq[2]=1; seq[3]=1; seq[4]=0;
    seq[5]=1; seq[6]=1; seq[7]=0; seq[8]=0; seq[9]=0;
    seq[10]=0; seq[11]=1; seq[12]=0; seq[13]=1; seq[14]=1;
    for (i = 0; i < 15; i = i + 1) exp[i] = 0;
    for (i = 3; i < 15; i = i + 1) begin
      match = 1'b0;
      if (seq[i-3]==1 && seq[i-2]==0 && seq[i-1]==1 && seq[i]==1)
        match = 1'b1;
      if (match) exp[i] = 1;
    end

    $dumpfile("tb_seq.vcd");
    $dumpvars(0, tb_seq);

    rst_n = 0;
    #20 rst_n = 1;

    // 复位后先给个 0，确认不误报
    @(negedge clk); din = 0;
    @(posedge clk); #1; check(0, -1);

    // 逐位喂入：在负沿摆好 din，正沿采样 det
    for (i = 0; i < 15; i = i + 1) begin
      @(negedge clk);
      din = seq[i];
      @(posedge clk); #1;
      check(exp[i], i);
    end

    // 结尾补 4 个 0，确认 det 回落、不残留
    for (i = 0; i < 4; i = i + 1) begin
      @(negedge clk); din = 0;
      @(posedge clk); #1; check(0, 100 + i);
    end

    if (err == 0) $display(">>> tb_seq PASS (命中3次, 无多余脉冲)");
    else          $display(">>> tb_seq FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #2000 $display(">>> tb_seq TIMEOUT"); $finish; end
endmodule
