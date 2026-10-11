// 手撕练习：UART 发送（8N1，波特率可配）—— 自己补全实现
//
// 干什么用的：把 8 位并行数据一位一位地"串"到一根线上，接收端按同样的节拍还原。
//             这是和上位机说话的嘴：项目里"样本经 UART 注入 BRAM / 结果回传 PC"就靠它。
//
// 帧格式（8N1，空闲时线为高）：
//      ┌ 起始位 ┐ ┌───── 8 个数据位, LSB 先 ─────┐ ┌ 停止位 ┐
//   ───┘  0     └ b0 b1 b2 b3 b4 b5 b6 b7 ───────┘   1     └─── 空闲(1)
//   每一位的长度 = DIV 拍 = CLK_FREQ/BAUD 拍（本题 50MHz/115200 → 434 拍）
//
// 规格（判分台严格按这个来，拍数不能差）：
//   1) 异步复位低有效：tx=1, busy=0
//   2) 空闲：tx=1（高电平）、busy=0；tx_start 高 1 拍就开始发一帧
//   3) 起始位必须在**采样到 tx_start 的那一拍**就拉低（不是下一拍），
//      之后每隔 DIV 拍换一位：起始位 → b0 → b1 → ... → b7 → 停止位(1)
//   4) 数据位 LSB 先发：第 1 个数据位是 tx_data[0]，最后一个才是 tx_data[7]
//   5) busy 覆盖整帧：从起始位起点到停止位结束共 10 个位时间都是 1，然后落 0
//   6) 忙的时候（busy=1）来的 tx_start 一律**忽略**：既不打断当前帧，也不排队补发
//
// 记忆套路：
//   发送 = "状态机 + 一个数到 DIV-1 的位计数器"，一个 always 就够。
//   本实现用"统一字段计数"：bit_cnt 把 10 个位统一编号 ——
//     0 = 起始位, 1..8 = d0..d7, 9 = 停止位；
//   每 DIV 拍 bit_cnt 推进一步，进去的那一拍就把 tx 摆成该位的电平
//     （起始位 0 / 数据位 = sh[0] 且 sh 右移 / 停止位 1）。
//   - 起始位是"低"，是特殊电平，所以在采样到 tx_start 的那一拍显式 tx <= 0；
//   - 数据位 LSB 先：每换一位 tx <= sh[0]，再 sh <= {1'b0, sh[7:1]}；
//   - busy 全程为 1，最后一个停止位走完（bit_cnt==9 到头）才落 0；
//   - 忙时 tx_start 被忽略：只要不在 IDLE，代码根本不看它。
//
// 端口：
//   tx_start : 1 拍脉冲，请求发送（只在空闲时被采样）
//   tx_data  : 待发送的 8 位字节
//   tx       : 串行输出线，空闲为高
//   busy     : 整帧期间为 1，发完落 0
module uart_tx #(
  parameter CLK_FREQ = 50_000_000,   // 板载时钟频率(Hz)
  parameter BAUD     = 115200        // 波特率
)(
  input  wire       clk,
  input  wire       rst_n,
  input  wire       tx_start,
  input  wire [7:0] tx_data,
  output reg        tx,
  output reg        busy
);

  localparam DIV = CLK_FREQ / BAUD;   // 每一位占几拍

  localparam IDLE = 2'd0,
             SEND = 2'd1;

  reg [1:0]  state;
  reg [15:0] div_cnt;
  reg [3:0]  bit_cnt;   // 0=起始位, 1..8=d0..d7, 9=停止位
  reg [7:0]  sh;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= IDLE;
      div_cnt <= 0;
      bit_cnt <= 0;
      sh      <= 0;
      tx      <= 1'b1;
      busy    <= 1'b0;
    end
    else if (state == IDLE) begin
      tx <= 1'b1;
      if (tx_start) begin          // 采样到 tx_start 当拍就拉起始位
        busy    <= 1'b1;
        tx      <= 1'b0;
        sh      <= tx_data;
        div_cnt <= 0;
        bit_cnt <= 0;
        state   <= SEND;
      end
    end
    else begin                     // SEND：每 DIV 拍推进一步
      if (div_cnt == DIV - 1) begin
        div_cnt <= 0;
        if (bit_cnt == 4'd9) begin // 停止位也送完 → 收工
          busy  <= 1'b0;
          tx    <= 1'b1;
          state <= IDLE;
        end
        else begin
          bit_cnt <= bit_cnt + 1'b1;
          if (bit_cnt + 1'b1 == 4'd9)
            tx <= 1'b1;            // 进停止位
          else begin
            tx <= sh[0];           // 数据位 LSB 先
            sh <= {1'b0, sh[7:1]};
          end
        end
      end
      else
        div_cnt <= div_cnt + 1'b1;
    end
  end

endmodule
