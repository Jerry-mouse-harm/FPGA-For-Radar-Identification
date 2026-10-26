`timescale 1ns/1ns
// 诊断用：逐个 (通道,位置) 放单脉冲，打印 step0 末尾 lane0 的输入电流 x_final。
// 期望 x = B1[0] + W1[0][ch*32 + (p>>1)]（B1[0]=6）。
module probe_fc1;
  localparam NPIN = 64, CI = 16, T = 16, NR = 32;
  reg clk = 0, rst_n = 0, in_valid = 0;
  reg [3:0] in_ch = 0, in_step = 0;
  reg [NPIN-1:0] in_spike = 0;
  wire busy, frame_start, spk_valid, frame_done;
  wire [NR-1:0] spk_vec;

  fc1_array #(.NPIN(NPIN), .NP(32), .CI(CI), .T(T), .NR(NR),
              .VW(16), .XW(16), .TW(16)) u_dut (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
    .in_ch(in_ch), .in_step(in_step), .in_spike(in_spike),
    .busy(busy), .frame_start(frame_start), .spk_valid(spk_valid),
    .spk_vec(spk_vec), .frame_done(frame_done));

  always #5 clk = ~clk;

  integer i, ci, k, ch, p;
  integer CHS [0:2];
  integer PS  [0:4];
  initial begin
    CHS[0] = 0; CHS[1] = 1; CHS[2] = 15;
    PS[0] = 0; PS[1] = 1; PS[2] = 31; PS[3] = 32; PS[4] = 63;
    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;

    for (ci = 0; ci < 3; ci = ci + 1) begin
      for (k = 0; k < 5; k = k + 1) begin
        ch = CHS[ci]; p = PS[k];
        $display("=== case ch=%0d p=%0d (expect x = 6 + W1[0][%0d]) ===",
                 ch, p, ch*32 + (p >> 1));
        for (i = 0; i < CI*T; i = i + 1) begin
          @(negedge clk);
          in_ch    = i / T;
          in_step  = i % T;
          in_spike = ((i / T) == ch) ? (64'd1 << p) : 64'd0;
          in_valid = 1'b1;
        end
        @(negedge clk) in_valid = 1'b0;
        @(posedge frame_done);
        @(negedge clk);
      end
    end
    $finish;
  end

  always @(posedge clk) begin
    if (rst_n && u_dut.state == 3'd2)
      $display("  [stepstart] step=%0d rd_addr=%h", u_dut.step_q, u_dut.rd_addr);
    if (rst_n && u_dut.state == 3'd3 && u_dut.step_q == 4'd0 &&
        (u_dut.c_q == 0 || u_dut.c_q == 31 || u_dut.c_q == 32 || u_dut.c_q == 511))
      $display("  c=%0d rd_addr=%h rd_data=%h bit_sr=%h in_bit=%b mem0=%h mem32=%h",
               u_dut.c_q, u_dut.rd_addr, u_dut.rd_data, u_dut.bit_sr, u_dut.in_bit,
               u_dut.in_mem[0], u_dut.in_mem[32]);
    if (rst_n && u_dut.state == 3'd3 && u_dut.step_q == 4'd0 && u_dut.c_q == 9'd511)
      $display("  step0 x_final[0]=%0d acc=%0d w0=%0d",
               u_dut.g_lane[0].x_final, u_dut.g_lane[0].acc, u_dut.g_lane[0].w_byte);
  end
endmodule
