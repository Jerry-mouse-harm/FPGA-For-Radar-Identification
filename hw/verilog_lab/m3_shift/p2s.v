// 手撕练习：并串转换（Parallel-to-Serial）—— 自己补全实现
//
// 干什么用的：把 WIDTH 位的并行数据一位一位送出去，最高位先出。
//             串口发送、往片外器件灌配置流，都是这个结构。
//
// 规格（判分台严格按这个来，拍数不能差）：
//   1) 异步复位低有效：q=0, cnt=0, busy=0, dout=0
//   2) 空闲（busy=0）：dout=0
//   3) load=1 的那一拍（判分台保证只高 1 拍）：
//        busy <= 1, cnt <= 0, dout <= din[WIDTH-1]     // 最高位当场摆出去
//   4) 之后 busy=1 的每一拍：
//        dout <= q[WIDTH-2];  q <= {q[WIDTH-2:0], 1'b0};  cnt <= cnt + 1
//   5) cnt 数到 WIDTH-1 的那一拍收工：busy <= 0, dout <= 0, cnt <= 0
//
//   合起来：从 load 那一拍算起，连续 WIDTH 拍依次输出
//   din[WIDTH-1], din[WIDTH-2], ..., din[0]；再下一拍 busy 落 0、dout 归 0。
//
// 记忆套路：
//   并串 = "一个装载点 + 一个移位 + 一个数到 WIDTH-1 就停的计数器"
//   - load 那一拍就直接把最高位摆到 dout（别等下一拍，否则整体晚一拍）
//   - 第 4 步取 q[WIDTH-2] 而不是 q[WIDTH-1]：最高位第 3 步已经送过了，不能重复送
//   - 分支顺序 load 优先于 busy（if / else if 的先后就决定了优先级）
//
// 需要你写：q/cnt 的声明（busy/dout 是端口）、三条分支（复位 / load / busy）、
//           计数器 cnt 的位宽（够数到 WIDTH-1 就行）
//
// 端口：
//   load : 并行载入脉冲（1 拍）
//   din  : 待发送的 WIDTH 位并行数据
//   dout : 串行输出，最高位先出
//   busy : 发送期间为 1（共 WIDTH 拍），空闲为 0
module p2s #(
  parameter WIDTH = 8
)(
  input  wire clk,
  input  wire rst_n,
  input  wire load,
  input  wire [WIDTH-1:0] din,
  output reg  dout,
  output reg  busy
);
  reg [WIDTH-1:0] cnt;
  reg [WIDTH-1:0] p;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p <= 0;
      cnt <= 0;
      busy <= 0;
      dout <= 0;
    end
    else if (load) begin
      busy <= 1;
      cnt <= 0;
      p <= din[WIDTH-1:0];
      dout <= din[WIDTH-1];
    end
    else if (busy) begin
      if (cnt == WIDTH - 1) begin
        cnt <= 0;
        busy <= 0;
        dout <= 0;
      end
      else begin
        dout <= p[WIDTH-2];
        p <= {p[WIDTH-2:0], 1'b0};
        cnt <= cnt + 1;
      end
    end
  end
  

endmodule
