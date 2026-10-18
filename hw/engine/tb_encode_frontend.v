`timescale 1ns/1ns
// tb_encode_frontend: 128 路编码前端判分台（自动 PASS/FAIL）
//
// 判什么：
//   · 13 帧样本（边界帧 + 舍入 tie 帧 + 5 类真实雷达信号），每帧 128 样本
//   · 每帧应吐 16 个 128-bit 向量（step 0..15），逐位与 golden.hex 比对
//   · 握手：start 后 busy 起、16 拍 step_valid、done、busy 落、能连续跑下一帧
//
// 模型假设（与题面一致）：
//   · BRAM 是同步读：smp_addr 发出后，smp_data 在**下一拍**才有效
//   · 判分台不卡装载拍数，只卡"16 个向量的内容和顺序"
//
// 空骨架预期：FAIL，err > 0（不会 TIMEOUT——每帧最多观察 MAX_CYCLES 拍）
module tb_encode_frontend;

  localparam N  = 128;
  localparam T  = 16;
  localparam AW = 7;
  localparam NF = 13;              // 与 gen_vectors.py 的帧数一致
  localparam MAX_CYCLES = 500;     // 单帧最大观察拍数（正常约 150 拍）

  reg  clk = 0;
  reg  rst_n = 0;
  reg  start = 0;

  wire              busy;
  wire [AW-1:0]     smp_addr;
  wire signed [7:0] smp_data;
  wire [N-1:0]      spike_vec;
  wire              step_valid;
  wire              done;

  encode_frontend #(
    .N  (N),
    .T  (T),
    .AW (AW)
  ) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (start),
    .busy      (busy),
    .smp_addr  (smp_addr),
    .smp_data  (smp_data),
    .spike_vec (spike_vec),
    .step_valid(step_valid),
    .done      (done)
  );

  // ---- 同步读 BRAM 模型：地址后 1 拍出数据 ----
  reg signed [7:0] smp_data_r;
  assign smp_data = smp_data_r;

  reg signed [7:0] rom [0:N-1];
  always @(posedge clk) smp_data_r <= rom[smp_addr];

  // ---- 金标准 ----
  reg signed [7:0] frames [0:NF*N-1];   // 帧 f 的样本 i 在 f*N+i
  reg [N-1:0]      golden [0:NF*T-1];   // 帧 f 的步 t 在 f*T+t

  integer err = 0;
  integer f, i, vidx, cyc;

  always #5 clk = ~clk;

  initial begin
    $dumpfile("tb_encode_frontend.vcd");
    $dumpvars(0, tb_encode_frontend);
    $readmemh("frame.hex", frames);
    $readmemh("golden.hex", golden);

    rst_n = 0;
    repeat (3) @(posedge clk); #1;
    @(negedge clk); rst_n = 1;

    for (f = 0; f < NF; f = f + 1) begin
      // 在负沿把当前帧拷进 ROM 模型（避开采样沿）
      @(negedge clk);
      for (i = 0; i < N; i = i + 1) rom[i] = frames[f*N + i];

      start = 1'b1;
      @(negedge clk);
      start = 1'b0;

      // start 被采样后 busy 应该起来
      @(posedge clk); #1;
      if (busy !== 1'b1) begin
        $display("FAIL frame %0d: start 后 busy=%b (expect 1)", f, busy);
        err = err + 1;
      end

      // 收 16 个向量
      vidx = 0;
      for (cyc = 0; cyc < MAX_CYCLES; cyc = cyc + 1) begin
        @(posedge clk); #1;

        if (step_valid === 1'b1) begin
          if (vidx < T) begin
            if (spike_vec !== golden[f*T + vidx]) begin
              $display("FAIL frame %0d step %0d:\n  got    %032h\n  expect %032h",
                       f, vidx, spike_vec, golden[f*T + vidx]);
              err = err + 1;
            end
          end else begin
            $display("FAIL frame %0d: 多出第 %0d 个 step_valid", f, vidx + 1);
            err = err + 1;
          end
          vidx = vidx + 1;
        end

        if (done === 1'b1) break;
      end

      if (vidx < T) begin
        $display("FAIL frame %0d: 只看到 %0d/%0d 个 step_valid", f, vidx, T);
        err = err + (T - vidx);
      end
      if (done !== 1'b1) begin
        $display("FAIL frame %0d: %0d 拍内没等到 done", f, MAX_CYCLES);
        err = err + 1;
      end

      // done 后下一拍：step_valid 必须落下
      @(posedge clk); #1;
      if (step_valid === 1'b1) begin
        $display("FAIL frame %0d: done 后 step_valid 仍为 1", f);
        err = err + 1;
      end

      // busy 应在 done 后 1 拍内落（留 1 拍余量）
      if (busy !== 1'b0) begin
        @(posedge clk); #1;
      end
      if (busy !== 1'b0) begin
        $display("FAIL frame %0d: done 后 busy 仍为 %b", f, busy);
        err = err + 1;
      end
    end

    if (err == 0)
      $display(">>> tb_encode_frontend PASS (%0d 帧 × %0d 步 × %0d 路全对)", NF, T, N);
    else
      $display(">>> tb_encode_frontend FAIL (err=%0d)", err);
    $finish;
  end

  initial begin
    #500000;
    $display(">>> tb_encode_frontend TIMEOUT");
    $finish;
  end

endmodule
