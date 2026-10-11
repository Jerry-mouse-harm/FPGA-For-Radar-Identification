// 手撕练习：边沿检测 → 单脉冲 —— 自己补全实现
//
// 干什么用的：给一个缓慢变化的信号 sig_in，检测它"跳变"的那一下，
//             输出一个干净的单时钟脉冲（rise/fall），供后续逻辑作"事件"用。
//             （例如：按键按下、FIFO 满标志、串口数据到达……）
//
// 记忆套路：
//   1) sig_d <= sig_in      // 打一拍：把上一拍的输入存下来
//   2) 组合判断：
//      rise 条件 = 现在=1 且 上一拍=0   → sig_in & ~sig_d
//      fall 条件 = 现在=0 且 上一拍=1   → ~sig_in & sig_d
//   3) 为了让脉冲宽整整 1 拍、且不含毛刺，再把这些条件"寄存一拍"输出
//      （即 rise/fall 用 reg，在时钟沿把上面条件锁存；比实际边沿晚 1 拍）
//   4) 异步复位低有效：sig_d=0, rise=0, fall=0
//
// 端口：
//   sig_in: 被检测信号（变化频率应远低于 clk）
//   rise : sig_in 0→1 后输出 1 拍高脉冲
//   fall : sig_in 1→0 后输出 1 拍高脉冲
module edge_det (
  input  wire clk,
  input  wire rst_n,
  input  wire sig_in,
  output reg  rise,
  output reg  fall
);

  reg sig_d;
  always@(posedge clk or negedge rst_n) begin
    if (! rst_n) begin
      sig_d <= 0;
      rise <= 0;
      fall <= 0;
    end
    else begin
      rise <= sig_in & ~sig_d;
      fall <= ~sig_in & sig_d;
      sig_d <= sig_in;
    end
  end
  // TODO: 手撕

endmodule
