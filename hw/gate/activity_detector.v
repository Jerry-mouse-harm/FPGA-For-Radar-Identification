// 手撕练习：活动检测（静息域 · 门控的第一块）—— 自己补全实现
//
// 干什么用的：静息态"常开"的眼睛。它盯着 BRAM 送来的原始样本流，每 W 个样本算一次
//             "窗内能量" Σ|din|，越过阈值就报 active=1（有活动 → 该唤醒引擎了）；
//             能量掉到低位再报 active=0（回静息）。**它是门控域闸门信号的来源。**
//
// 为什么用"窗 + 滞回"：
//   · 窗：单看一个样本会被噪声骗，攒 W 个样本的能量更稳（顺便把判决频率降到 1/W）。
//   · 滞回：只有一个阈值时，能量在阈值附近抖 → active 反复横跳 → 引擎被反复唤醒（费电）。
//     设两个阈值（TH_ON > TH_OFF），中间夹一条"死区"，在死区里**保持原状态**，抖动就进不来。
//
// 规格（判分台严格按这个来）：
//   1) 异步复位低有效：s_cnt=0, acc=0, active=0
//   2) 只有 din_valid=1 的样本才计数；din_valid=0 的拍**什么都不做**（窗不前进）
//   3) e = |din|（8 位无符号绝对値）
//   4) 每个有效样本：acc += e；s_cnt 从 0 数到 W-1（数满 W 个 = 一个窗）
//   5) 第 W 个样本落下的那一拍 = **窗边界**，此刻做判决：
//          窗和 = acc + e            ← 必须把**这一个**样本也算进去!
//          ≥ TH_ON  → active <= 1
//          ≤ TH_OFF → active <= 0
//          否则      → active 保持不变（滞回）
//      判完 acc / s_cnt 归零，下一样本立即开始新窗（背靠背，不许丢样本）
//   6) active 只在窗边界变，窗内恒定
//
// 记忆套路：
//   · |din|：有符号数取绝对值 = "看符号位，是 1 就按位取反再加 1"（二补码取负）。
//     写成 `din[7] ? (~din + 8'd1) : din`；别写 `0 - din`（din=-128 时会溢出错）。
//   · 计数器当"窗边界"：硬件里没有"一窗"这个东西，是数出来的（M1 的老套路）。
//   · **最容易错的在第 5 步的 `acc + e`**：acc 装的是"前 W-1 个"的和，漏了当前这个，
//     窗和就系统性偏小 → 卡在阈值附近的窗会判反。判分台有一个用例专门卡这个（off-by-one）。
//   · 位宽别拍脑袋：acc 装 W 个 ≤128 的数，W=16 时最大 2048 → 要 12 位，给 8 位会溢出。
//     （提示：`$clog2(W) + 8`）
//
// 自适应阈值（ADAPT=1，噪声底跟踪 = CFAR 最简单版）：
//   环境噪声底会随 SNR/干扰漂移，写死阈值在低 SNR 下会被噪声顶穿 → active 卡死/虚警。
//   这里加一个"泄漏最小值跟踪"器 nf 估计噪声底（窗能量的低端），阈值随它浮动：
//       nf 每窗更新：win_sum < nf ? nf <= win_sum（向下立即跟随）
//                                : nf <= nf + (nf>>NF_RISE_SH) + 1（向上慢升）
//       th_on  = 2   * nf
//       th_off = 1.5 * nf   (= nf + (nf>>1))
//   nf 初值取满（全 1）：首窗不会误触发，且立即被第一个静息窗拉到底噪。
//   ⚠ 假设信号是"间歇"的（有静息窗可估底噪）；连续信号（CW）下 nf 会慢慢爬到信号电平，
//     那是另一码事（见 hw/gate/INTERFACE.md 讨论），这里先做最基础的。
//
// 端口：
//   din       : BRAM 送来的原始样本，有符号 8 位定点（x = din/16）
//   din_valid : 1 = 本拍 din 是一个新样本
//   active    : 1 = 检测到活动（带滞回的电平），喂给 gate_ctrl
module activity_detector #(
  parameter W           = 16,     // 判决窗长（样本数）
  parameter TH_ON       = 1024,   // 判"有活动"的窗和阈值（ADAPT=0 时用）
  parameter TH_OFF      = 512,    // 判"回静息"的窗和阈值（ADAPT=0 时用）
  parameter ADAPT       = 0,      // 0=固定阈值（判分台默认）; 1=噪声底自适应阈值
  parameter NF_RISE_SH  = 6       // ADAPT=1 时噪声底每窗慢升速率：nf += (nf>>SH)+1
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire signed [7:0] din,
  input  wire              din_valid,
  output reg               active
);

  localparam CNT_W = $clog2(W);      // s_cnt 位宽
  localparam ACC_W = $clog2(W) + 8;  // acc / 窗和 位宽

  reg [ACC_W-1:0] acc;    // 窗内（前 W-1 个）能量累加
  reg [CNT_W-1:0] s_cnt;  // 窗内计数 0..W-1
  reg [ACC_W-1:0] nf;     // 噪声底估计（ADAPT=1 时用；泄漏最小值跟踪）

  // |din|：二补码取负 = 按位取反加 1（din=-128 也不会溢出，别写 0-din）
  wire [7:0]       e       = din[7] ? (~din + 8'd1) : din[7:0];
  wire [ACC_W-1:0] win_sum = acc + e;   // 含当前样本的窗和

  // 阈值：ADAPT=0 用固定参数；ADAPT=1 用噪声底浮动阈值（th_on=2nf, th_off=1.5nf）
  wire [ACC_W-1:0] th_on  = ADAPT ? (nf << 1)              : TH_ON[ACC_W-1:0];
  wire [ACC_W-1:0] th_off = ADAPT ? (nf + (nf >> 1))       : TH_OFF[ACC_W-1:0];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc    <= {ACC_W{1'b0}};
      s_cnt  <= {CNT_W{1'b0}};
      active <= 1'b0;
      nf     <= {ACC_W{1'b1}};   // 初值取满：首窗不误触发，随即被第一个静息窗拉到底噪
    end
    else if (din_valid) begin
      if (s_cnt == W - 1) begin          // 窗边界：第 W 个样本落下
        if      (win_sum >= th_on)  active <= 1'b1;
        else if (win_sum <= th_off) active <= 1'b0;   // 中间带：保持（滞回）
        // 噪声底跟踪（ADAPT=1 才有意义；ADAPT=0 时 nf 不参与判决，综合会被裁掉）
        if (win_sum < nf) nf <= win_sum;                        // 向下：立即跟随
        else              nf <= nf + (nf >> NF_RISE_SH) + 1'b1; // 向上：慢升
        acc   <= {ACC_W{1'b0}};
        s_cnt <= {CNT_W{1'b0}};          // 背靠背，下一样本立即开新窗
      end
      else begin
        acc   <= win_sum;                // 累加（必须含当前样本）
        s_cnt <= s_cnt + 1'b1;
      end
    end
  end

endmodule
