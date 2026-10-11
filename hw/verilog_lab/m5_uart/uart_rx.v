// 手撕练习：UART 接收（8N1，波特率可配）—— 自己补全实现
//
// 干什么用的：tx 的反向动作。盯着 rx 线，等一个起始位，然后按节拍一位一位收满 8 位，
//             给出并行结果 + 一个 valid 脉冲。上位机给板子发命令、发样本，靠的就是它。
//
// 帧格式（8N1，同 uart_tx，空闲时线为高）：
//      ┌ 起始位 ┐ ┌───── 8 个数据位, LSB 先 ─────┐ ┌ 停止位 ┐
//   ───┘  0     └ b0 b1 b2 b3 b4 b5 b6 b7 ───────┘   1     └───
//   每一位的长度 = DIV 拍 = CLK_FREQ/BAUD 拍（本题 50MHz/115200 → 434 拍）
//
// 规格（判分台严格按这个来）：
//   1) 异步复位低有效：dout=0, valid=0
//   2) 空闲时 rx 为高；看到 rx 的**下降沿**（上一拍 1、这一拍 0）→ 疑似起始位，进"起始位确认"
//   3) 再等 DIV/2 拍（此时正好在起始位正中间）复检：rx 仍为 0 → 真起始位，进入收数；
//      若已回到 1 → 是毛刺，直接回空闲，不许产生 valid
//   4) 此后每隔 DIV 拍采样一次 rx，连采 8 次，**LSB 先**：第 1 次采到的是 b0，最后一次是 b7
//      （写法提示：sh <= {rx, sh[7:1]} —— 往右挤，8 次之后最先收到的位正好落在 sh[0]）
//   5) 第 8 位采完再等 DIV 拍（此时在停止位正中间）采样：rx=1 → dout <= sh, valid 拉高；
//      rx=0（帧错误）就当没收到，不产生 valid。无论如何都回空闲
//   6) valid **只高 1 拍**，且只在刚收满一帧时出现；两帧背靠背也不能多打、不能错位
//
// 记忆套路：
//   接收 = "等下降沿 → 半位复检 → 每 DIV 拍采一位"，一共四态：IDLE/START/DATA/STOP。
//   - 为什么非要半位复检：光看边沿会被线上毛刺骗；退到位的正中间再确认一次，
//     顺带把采样点对齐到每一位的**中点**（后面每 DIV 拍采一次就都落在中点，容错最大）
//   - 为什么采样要在中点：起始位从边沿算起半位后是中点，之后每 DIV 拍仍在中点，
//     收发两边时钟差 ±10% 也采不错
//   - 判边沿要先打个拍：用 rx_d 存上一拍的 rx，条件是 (rx_d & ~rx)。
//     直接把 rx 拿去当条件，组合毛刺会误触发
//   - valid 的"默认清零"写在 always 开头（valid <= 0），完成分支里再 valid <= 1；
//     同一个 always 里对同一信号的后一次赋值生效 —— 天然就是 1 拍脉冲
//
// 需要你写：状态编码 localparam、state/div_cnt/bit_cnt/sh/rx_d 的声明、
//           一个 always 块里的四态分支（div_cnt 给 [15:0]，理由同 uart_tx）
//
// 端口：
//   rx    : 串行输入线，空闲为高
//   dout  : 收到的字节（valid=1 时有效）
//   valid : 收满一帧时脉冲 1 拍
module uart_rx #(
  parameter CLK_FREQ = 50_000_000,   // 板载时钟频率(Hz)
  parameter BAUD     = 115200        // 波特率
)(
  input  wire       clk,
  input  wire       rst_n,
  input  wire       rx,
  output reg  [7:0] dout,
  output reg        valid
);

  localparam DIV  = CLK_FREQ / BAUD;   // 每一位占几拍 = 434
  localparam HALF = DIV / 2;           // 半位 = 起始位中点采样点

  localparam IDLE  = 2'd0,
             START = 2'd1,
             DATA  = 2'd2,
             STOP  = 2'd3;

  reg [1:0]  state;
  reg [15:0] div_cnt;
  reg [2:0]  bit_cnt;
  reg [7:0]  sh;
  reg        rx_d;          // 上一拍的 rx，用于判下降沿

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= IDLE;
      div_cnt <= 0;
      bit_cnt <= 0;
      sh      <= 0;
      rx_d    <= 1'b1;
      dout    <= 0;
      valid   <= 0;
    end
    else begin
      rx_d  <= rx;            // 每拍记下 rx，供下一拍判边沿
      valid <= 1'b0;          // 默认清零 → valid 天然只高 1 拍

      case (state)
        IDLE: begin
          div_cnt <= 0;
          if (rx_d & ~rx)     // 下降沿 → 疑似起始位
            state <= START;
        end

        START: begin          // 等半位，到起始位正中间复检
          if (div_cnt == HALF - 1) begin
            div_cnt <= 0;
            if (~rx) begin    // 仍为低 → 真起始位
              state   <= DATA;
              bit_cnt <= 0;
            end
            else              // 已回高 → 毛刺，回空闲
              state <= IDLE;
          end
          else
            div_cnt <= div_cnt + 1'b1;
        end

        DATA: begin           // 之后每 DIV 拍采一位，LSB 先
          if (div_cnt == DIV - 1) begin
            div_cnt <= 0;
            sh      <= {rx, sh[7:1]};       // 最先收到的位 8 拍后落到 sh[0]
            if (bit_cnt == 3'd7)
              state <= STOP;
            else
              bit_cnt <= bit_cnt + 1'b1;
          end
          else
            div_cnt <= div_cnt + 1'b1;
        end

        STOP: begin           // 等 DIV 拍，采停止位
          if (div_cnt == DIV - 1) begin
            div_cnt <= 0;
            state   <= IDLE;
            if (rx) begin     // 停止位为高 → 收满
              dout  <= sh;
              valid <= 1'b1;  // 覆盖默认清零 → 只 1 拍
            end
          end
          else
            div_cnt <= div_cnt + 1'b1;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
