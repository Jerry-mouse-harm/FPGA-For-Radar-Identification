// 手撕练习：串并转换（Serial-to-Parallel）—— 自己补全实现
//
// 干什么用的：连着 WIDTH 拍一位一位地收，收满 WIDTH 位后一次性给出并行结果，
//             并打一个 valid 脉冲通知下游。UART 接收端、SPI 从机都是这个结构。
//
// 规格（判分台严格按这个来）：
//   1) 异步复位低有效：q=0, cnt=0, dout=0, valid=0
//   2) 每一拍都收 din（没有使能）：q <= {q[WIDTH-2:0], din}，cnt <= cnt + 1
//      即先收进来的位慢慢往高位跑 —— 第一个收到的位最终停在最高位
//   3) cnt 数到 WIDTH-1 的那一拍（正好收满第 WIDTH 位）：
//        dout <= {q[WIDTH-2:0], din};   // 把这一位也算进去，一次给全
//        valid <= 1;  cnt <= 0;
//   4) 其余拍 valid <= 0（valid 只高 1 拍）
//
//   位序约定：p2s 先送最高位，s2p 收到的第一位就当最高位 → 两者直连能原样还原。
//
// 记忆套路：
//   串并 = 移位寄存器 + 两件新东西：一个"数到 WIDTH-1"的计数器、一拍 valid 脉冲
//   坑在这里：输出必须也写成拼接 {q[WIDTH-2:0], din}，不能直接 dout <= q
//   —— q 里还差最后进来的这一位，直接用会少一位（这是本模块唯一的难点）
//
// 需要你写：q/cnt 的声明、移位 + 计数、cnt==WIDTH-1 的完成分支、valid 的默认清零
//
// 端口：
//   din   : 串行输入位
//   dout  : 收到的 WIDTH 位并行结果（valid=1 时有效）
//   valid : 收满 WIDTH 位时脉冲 1 拍
module s2p #(
  parameter WIDTH = 8
)(
  input  wire clk,
  input  wire rst_n,
  input  wire din,
  output reg  [WIDTH-1:0] dout,
  output reg  valid
);
  reg [WIDTH-1:0] p;
  reg [WIDTH-1:0] cnt;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= 0;
      valid <= 0;
      p <= 0;
      dout <= 0;
    end
    else begin
      if (cnt == WIDTH-1) begin
        cnt <= 0;
        valid <= 1; 
        dout <= {p[WIDTH-2:0], din};
      end
      else begin
        p <= {p[WIDTH-2:0], din};
        cnt <= cnt + 1'b1;
        valid <= 0;
      end
    end
  end

endmodule
