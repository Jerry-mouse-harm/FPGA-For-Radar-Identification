// 手撕练习：按键消抖（Debounce）—— 自己补全实现
//
// 干什么用的：机械按键在按下/松开那一下会抖出十几个窄脉冲（毫秒级），
//             直接拿去当"事件"会一次按键触发好几次。
//             这个模块把带抖的输入变成干净的电平：只有**连续稳定 CNT_MAX 拍**
//             才认，短于 CNT_MAX 的毛刺全部忽略。
//             （M5 的 UART 起止位、板上的复位键，前面都要挂一个它）
//
// 规格（判分台严格按这个来）：
//   1) 异步复位低有效：ff1=0, ff2=0, cnt=0, key_out=0
//   2) 每一拍无条件打两拍：ff1 <= key_in;  ff2 <= ff1;
//      （第 1 级消亚稳态，第 2 级才拿去判断 —— 单级同步器不够）
//   3) 拿 ff2 和"当前认可的电平" key_out 比较：
//        · ff2 == key_out  → cnt <= 0                 （没变化，计数清零）
//        · 否则 cnt 累加；数到 CNT_MAX-1 时 → key_out <= ff2, cnt <= 0
//   4) 效果：key_in 必须连续稳定 CNT_MAX 拍，key_out 才跟着翻；
//            从 key_in 变化到 key_out 跟上，一共约 2 + CNT_MAX 拍。
//            抖动（任何短于 CNT_MAX 拍的变化）都不会传到 key_out。
//
// 记忆套路：
//   消抖 = "两级同步器" + "一个数到 CNT_MAX-1 的计数器"
//   - 计数器的**清零条件**是本模块的题眼：只要"看到的不等于认可的"就清零，
//     等价于"必须连续稳定，中间抖一下就从头数"
//   - 别用 key_out 自己当门控（那会需要额外的状态位，而且容易忘了清零）
//   - 真实项目里 CNT_MAX = 消抖时间 / 时钟周期（如 20ms / 20ns = 1_000_000），
//     这里为了仿真快，默认只给 5
//
// 需要你写：ff1/ff2/cnt 的声明（cnt 位宽够数到 CNT_MAX-1）、
//           两级同步、比较 + 计数 + 认可这三件事
//
// 端口：
//   key_in  : 原始输入（异步、有抖动）
//   key_out : 消抖后的干净电平
module key_debounce #(
  parameter CNT_MAX = 5
)(
  input  wire clk,
  input  wire rst_n,
  input  wire key_in,
  output reg  key_out
);
  reg ff1, ff2;                        // 两级同步器：各 1 bit，只管"把异步变干净"
  reg [$clog2(CNT_MAX)-1:0] cnt;       // 要数到 CNT_MAX-1，$clog2 刚刚好

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ff1     <= 1'b0;
      ff2     <= 1'b0;
      cnt     <= 0;
      key_out <= 1'b0;
    end
    else begin
      // ① 两级同步：每一拍无条件打，绝不放进任何 if 里
      ff1 <= key_in;                   // 第 1 级：喂给亚稳态
      ff2 <= ff1;                      // 第 2 级：干净的，拿去判断

      // ② 比较 + 计数 + 认可
      if (ff2 == key_out) begin
        cnt <= 0;                      // 和认可的相同 → 没在变，清零
      end
      else if (cnt == CNT_MAX - 1) begin
        key_out <= ff2;                // 连续稳定满 CNT_MAX 拍 → 认可新电平
        cnt     <= 0;
      end
      else begin
        cnt <= cnt + 1'b1;             // 还在数；中途 ff2 一变回 key_out 就走上面清零
      end
    end
  end

endmodule
