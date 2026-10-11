// 手撕练习：串入并出移位寄存器（SIPO）—— 自己补全实现
//
// 干什么用的：每来一拍就把 din 挤进寄存器最低位，原来的位整体左移一格。
//             它是"延迟线"的最小模型——第 k 位输出就是 k 拍之前的输入。
//             （SNN 的 T 步调度、FIR 抽头延迟、UART 串转并，底层都是它）
//
// 规格（判分台严格按这个来）：
//   1) 异步复位低有效：rst_n=0 → q=0
//   2) en=0 → q 保持不动          （这就是"时间步调度"里的那个开关）
//   3) en=1 → q <= {q[WIDTH-2:0], din}   // 左移一位，新位从最低位进入
//      推论：先喂进来的位会慢慢跑到高位；喂 WIDTH 位之后，
//            第 1 个喂的位停在 q[WIDTH-1]
//   4) 位宽参数化，默认 WIDTH=8
//
// 记忆套路：
//   q 是 WIDTH 位寄存器，"整体挪一格"用位拼接描述：
//     左移：{q[WIDTH-2:0], din}       右移：{din, q[WIDTH-1:1]}
//   拼接的宽度必须正好等于 WIDTH，多一位少一位会悄悄改位宽（不报错，只出错）
//
// 需要你写：q 的声明、带 en 的使能判断、那条位拼接移位
//
// 端口：
//   din : 串行输入位
//   q   : 并行的 WIDTH 位输出（q[WIDTH-1] 是最早进来的位）
//   en  : 使能，高电平才移位
module shift_reg #(
  parameter WIDTH = 8
)(
  input  wire clk,
  input  wire rst_n,
  input  wire en,
  input  wire din,
  output reg  [WIDTH-1:0] q
);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)   q <= 0;
    else if (en)  q <= {q[WIDTH-2:0], din};
  end

endmodule
