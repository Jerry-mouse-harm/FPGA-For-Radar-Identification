`timescale 1ns/1ns
module probe_rom;
  reg clk = 0;
  reg [8:0] a = 0;
  wire [255:0] dw;
  wire signed [511:0] db, dt;
  fc1_wrom u (.clk(clk), .addr_w(a), .dout_w(dw), .dout_b(db), .dout_t(dt));
  always #5 clk = ~clk;
  integer i;
  initial begin
    for (i = 0; i < 4; i = i + 1) begin
      @(negedge clk) a = i;
      @(posedge clk); #1;
      $display("a=%0d dw=%h", a, dw);
    end
    @(posedge clk); #1;
    $display("db=%h", db);
    $display("dt=%h", dt);
    $finish;
  end
endmodule
