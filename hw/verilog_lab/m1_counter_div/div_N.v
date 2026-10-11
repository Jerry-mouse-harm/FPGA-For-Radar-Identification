// 手撕练习：任意整数 N 分频（50% 占空，输出频率 = clk/N）—— 自己补全实现
//
// 记忆套路：
//   1) 一个模 N 计数器 cnt：0..N-1 循环（数到 N-1 回 0）
//   2) clk_p：在"上升沿"判断，当 cnt==(N-1)/2 或 cnt==N-1 时翻转
//      （这个信号对偶数 N 已经是精确 50%；对奇数 N 还不够——间隔长短交替）
//   3) clk_n：同一条件，但只在"下降沿"翻转 —— 用它给奇数 N 拼出半时钟精度
//   4) 关键：out_clk = (N 为偶数) ? clk_p          // 偶数直接用 clk_p
//                   : (clk_p | clk_n)               // 奇数才需要双沿 OR
//      （千万不要无条件 out = clk_p|clk_n！偶数会变 25/15 非 50%）
//   5) 异步复位低有效：cnt=0, clk_p=0, clk_n=0
//   6) cnt 位宽够放 N-1 即可（判分台用 N=4 和 N=5）
//
// 需要你写：cnt/clk_p/clk_n 声明、模 N 计数、两处翻转、按 (N%2==0) 三目选输出
module div_N #(
  parameter N = 5        // 分频系数
)(
  input  wire clk,
  input  wire rst_n,     // 异步复位，低有效
  output wire out_clk
);
  reg [3:0]cnt;
  reg clk_p;
  reg clk_n;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cnt <= 3'b0;
    else if (cnt == N-1) cnt <= 3'b0;
    else cnt <= cnt + 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) clk_p <= 0;
    else if (cnt == (N-1)/2 || cnt == N-1) clk_p <= ~clk_p;
  end
  
  always @(negedge clk or negedge rst_n) begin
    if (!rst_n) clk_n <= 0;
    else if (cnt == (N-1)/2 || cnt == N-1) clk_n <= ~clk_n;
  end

  assign out_clk = (N/2 == (N+1)/2) ? clk_p : (clk_p | clk_n);

endmodule
