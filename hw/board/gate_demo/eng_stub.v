// eng_stub.v —— 假引擎（占位）：上板 demo 用，等同学的真引擎来了就换掉。
// 语义对齐 INTERFACE.md §3：eng_start 1 拍 → 从下一沿跑 T 步 → eng_done 1 拍 + eng_class。
// 跑在门控域（clk = clk_eng），异步复位低有效（eng_rst_n）。
module eng_stub #(parameter T = 16)(
  input  wire       clk,       // = clk_eng（门控域）
  input  wire       rst_n,     // = eng_rst_n
  input  wire       start,
  output reg        busy,
  output reg        done,
  output reg  [2:0] cls
);
  reg [4:0] step;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      step <= 5'd0; busy <= 1'b0; done <= 1'b0; cls <= 3'd0;
    end
    else begin
      done <= 1'b0;
      if (start) begin
        step <= 5'd0; busy <= 1'b1;
      end
      else if (busy) begin
        if (step == T - 1) begin
          busy <= 1'b0;
          done <= 1'b1;
          cls  <= 3'd3;      // 假装识别成类别 3
        end
        else step <= step + 1'b1;
      end
    end
endmodule
