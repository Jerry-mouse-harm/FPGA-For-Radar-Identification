`timescale 1ns/1ns
// tb_m6_chain: 端到端 —— din → n → 16 步脉冲序列（自动 PASS/FAIL）
//
// 为什么还要这个 tb：两个模块各自 PASS 只说明"各自符合自己的规格"，不说明两者的
//   **位宽/约定**接得上（n 只有 5 位、load 与第 0 步差一拍、T 步边界在哪）。
//   这里把 sample_to_n 的输出直接接到 spike_encoder 的 n 上，跑真样本流。
module tb_m6_chain;
  localparam T  = 16;
  localparam NS = 27;

  reg clk = 0, rst_n = 0, load = 0;
  reg signed [7:0] din = 0;
  wire [4:0] n;
  wire spike;

  integer err = 0;
  integer i, t, exp_n;
  reg [15:0] svec [0:NS-1];
  reg [15:0] pat  [0:T];
  reg [15:0] exp_pat;

  sample_to_n   u_map (.din(din), .n(n));
  spike_encoder u_enc (.clk(clk), .rst_n(rst_n), .load(load), .n(n), .spike(spike));

  always #5 clk = ~clk;

  initial begin
    $dumpfile("tb_m6_chain.vcd");
    $dumpvars(0, tb_m6_chain);
    $readmemh("sample_n.hex", svec);
    $readmemh("n_pattern.hex", pat);

    rst_n = 0;
    repeat (3) @(posedge clk); #1;

    // 复位在"置 load"的同一个负沿释放（理由见 tb_spike_encoder）
    @(negedge clk); rst_n = 1;

    for (i = 0; i < NS; i = i + 1) begin
      exp_n   = svec[i][7:0];
      exp_pat = pat[exp_n];

      load = 1'b1; din = svec[i][15:8];
      @(posedge clk); #1;                 // load 被采样: n 由组合逻辑当拍稳定
      load = 1'b0;

      for (t = 0; t < T; t = t + 1) begin
        @(posedge clk); #1;
        if (spike !== exp_pat[t]) begin
          $display("FAIL din=%0d n=%0d step%0d @%0t: spike=%0b (expect %0b)",
                   din, exp_n, t, $time, spike, exp_pat[t]);
          err = err + 1;
        end
      end
    end

    if (err == 0) $display(">>> tb_m6_chain PASS (%0d 个样本, 端到端脉冲序列全对)", NS);
    else          $display(">>> tb_m6_chain FAIL (err=%0d)", err);
    $finish;
  end

  initial begin #200000 $display(">>> tb_m6_chain TIMEOUT"); $finish; end
endmodule
