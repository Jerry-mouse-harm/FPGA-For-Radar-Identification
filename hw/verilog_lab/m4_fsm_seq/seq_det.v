// 手撕练习：三段式状态机 —— 序列检测 "1011"（可重叠）—— 自己补全实现
//
// 干什么用的：串口/数据流里来一串比特，检测是否出现模式 "1011"。
//             "可重叠"指检测完一个后不回到原点：如 1 0 1 1 0 1 1
//             在第 4、第 7 位各命中一次。状态机 = 记录"已经匹配到模式前几位"。
//
// 状态定义（Moore，输出只看状态）：
//   IDLE : 一个都没匹配上
//   S1   : 已匹配 "1"
//   S2   : 已匹配 "10"
//   S3   : 已匹配 "101"
//   S4   : 已匹配 "1011"  ← 只有这态 det=1
//
// 状态转移表（din 是当前输入比特）：
//   状态    din=0         din=1
//   IDLE    IDLE          S1
//   S1      S2            S1        // 又来一个 1：末尾的 1 重新当"第一个1"
//   S2      IDLE          S3        // 变成 100：前面全作废
//   S3      IDLE          S4        // 变成 1010：作废
//   S4      S2            S1        // 命中后，末尾这个 1 当作新一轮的"第一个1"→可重叠
//
// 三段式记忆套路：
//   第1段（时序段）  state <= next_state           复位→IDLE
//   第2段（组合段）  case(state) 按上表算 next_state（default: state）
//   第3段（输出段）  det = (state == S4)            摩尔输出，只依赖状态
//
// 端口：
//   din: 每拍输入 1 bit；det: 命中那一拍输出 1
module seq_det (
  input  wire clk,
  input  wire rst_n,
  input  wire din,
  output reg  det
);

  // TODO: 手撕
  // 需要的零件：
  //   1) 状态编码 localparam  + reg 存状态（位宽够用即可）
  //   2) 第1段 always: posedge+异步复位, state <= next_state
  //   3) 第2段 always: 组合逻辑(*), case(state), 用 din 分支
  //   4) 第3段: assign 或 always 组合, det=(state==S4)
  // 注意：第2、3段是"组合"逻辑，要用阻塞 =；只有第1段时序用 <=


  // 000->TDLE 001、010、011、100->s1、s2、s3、s4
  reg [2:0]state, next_state;
  localparam IDLE = 3'b000, S1 = 3'b001, S2 = 3'b010, S3 = 3'b011, S4 = 3'b100;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= 3'b000;
    else state <= next_state;
  end

  always @(*) begin
    case(state)
      3'b000: next_state = (din == 0) ? IDLE : S1;
      3'b001: next_state = (din == 0) ? S2 : S1;
      3'b010: next_state = (din == 0) ? IDLE : S3;
      3'b011: next_state = (din == 0) ? IDLE : S4;
      3'b100: next_state = (din == 0) ? S2 : S1;
      default: next_state = IDLE;
    endcase
  end

  always @(*) begin
    det = (state == S4);
  end

endmodule
