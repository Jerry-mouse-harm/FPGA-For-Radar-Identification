// 单个 LIF 神经元（整数域：纯 IF + 软复位 + 16 位饱和）—— 识别引擎的最小计算单元
//
// 干什么用的：
//   SNN 阵列里的一个"细胞"。每个时间步把输入突触的加权和 + 偏置积到膜电位上，
//   越过阈值就发一个脉冲，然后减去阈值（软复位）。上一级已经把"脉冲 × 权重"
//   变成了条件加，所以这里**只有加法器 + 比较器，没有乘法器**。
//
// 和训练端（src/models/snn_conv.py :: QuantLIF）的逐行对应：
//     v = v + x[t]                 // LEAK_SHIFT=0 → 纯 IF，没有泄漏项
//     v = fake_quant_sym(v, 16)    // 硬件换成"固定尺度 s_w + 饱和"（见 README 契约 v0.1）
//     s = (v >= th)                // 注意是 >=，不是 >
//     v = v - th * s               // HARD_RESET=False → 软复位，每步最多减一次
//
// 固定点契约（hw/engine/lif/README.md）：
//     · 膜电位 LSB = s_w（该层权重的尺度），16 位有符号，饱和到 [-32768, 32767]
//     · 阈值 th_int = round(th / s_w)，约定 th_int >= 1（训练端阈值恒正）
//     · 输入 x_in = Σ(本步发放脉冲对应的 W_int) + b_int
//
// 时序（接阵列时严格按这个对齐）：
//     · step_valid=0：v_out / spike 完全冻结（纯 IF 没有泄漏，空闲不改变状态）
//     · step_valid=1 的上升沿：采样 x_in / th，更新 v_out 与 spike（寄存器输出）
//     · 即"第 t 步的结果"在本拍沿之后稳定；下一级阵列下一拍再用它算 x_in
//       —— 层间天然是 1 拍的流水线延迟，接缝处不要另外加寄存器
//
// 饱和顺序（和训练端 fake_quant_sym 的 clamp 对齐，不能换）：
//     先加 → 再饱和 → 再和 th 比较 → 再软复位。
//     如果先比较后饱和，大输入会绕过 16 位量化，和训练域对不上。
//
// 位宽与溢出：
//     VW=16 膜电位；XW 输入加权和位宽（默认 16；FC1 这种 512 扇入可例化时放大到 18）；
//     TW 阈值，约定 TW <= VW。
//     加法在 AW+1 位里做（AW=max(VW,XW)），两个操作数**先符号扩展再相加**；
//     避免 Verilog "表达式按最大操作数宽度计算、算完再扩位"的经典坑（会丢进位）。
//
// 自检锚点（判分台 tb_lif_neuron 里有这些用例）：
//     x=6,   th=100   → 16 步全不发（v=96，攒满也差 4）
//     x=10,  th=100   → 只在 t=9 发（v 正好攒到 100）—— 抓 >= / > 和 off-by-one
//     x=100, th=100   → 每步都发（v=100 → 发 → 减回 0）
//     x=32767, th=100 → 每步都发，v 稳定在 32667（饱和 32767 − 100）—— 抓漏饱和
//     x=-32768, th=100→ 16 步全不发，v 钉在 -32768
//     th=32767, x=2048→ t=15 时 32768 >= 32767，发（恰好撞线）
//     th=32767, x=2047→ 16 步全不发（32752 < 32767，差 15）
//
// 端口：
//   clk       : clk_eng（门控域时钟）
//   rst_n     : eng_rst_n（异步复位低有效）
//   step_valid: 1 = 本拍是一个有效时间步（前端 step_valid 接进来）
//   x_in      : 本步输入加权和（有符号，LSB = s_w）
//   th        : 整数阈值（>= 1，LSB = s_w）
//   spike     : 本步是否发放（寄存器输出，与 v_out 同拍）
//   v_out     : 本步更新后的膜电位（下一级/调试口都看它）
module lif_neuron #(
  parameter integer VW = 16,   // 膜电位位宽（契约固定 16）
  parameter integer XW = 16,   // 输入加权和位宽（默认 16，大扇入层例化时放大）
  parameter integer TW = 16    // 阈值位宽（约定 <= VW）
)(
  input  wire                 clk,
  input  wire                 rst_n,
  input  wire                 step_valid,
  input  wire signed [XW-1:0] x_in,
  input  wire signed [TW-1:0] th,
  output reg                  spike,
  output reg  signed [VW-1:0] v_out
);

  // 16 位有符号饱和边界：0111...1 = +32767，1000...0 = -32768
  localparam signed [VW-1:0] VMAX = {1'b0, {(VW-1){1'b1}}};
  localparam signed [VW-1:0] VMIN = {1'b1, {(VW-1){1'b0}}};

  // 加法器宽度：先取两者较宽者，再多 1 位装进位
  localparam integer AW = (XW > VW) ? XW : VW;

  // 先符号扩展、再相加（两边都扩到 AW+1 位，绝不会丢进位）
  wire signed [AW:0] vsum = {{(AW+1-VW){v_out[VW-1]}}, v_out}
                          + {{(AW+1-XW){x_in[XW-1]}}, x_in};

  // 饱和到 16 位有符号
  wire signed [VW-1:0] v_sat = (vsum > VMAX) ? VMAX :
                               (vsum < VMIN) ? VMIN : vsum[VW-1:0];

  // >= 而不是 >：v 恰好等于阈值时就要发放（训练端 s = (v >= th)）
  wire s_c = (v_sat >= th);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_out <= {VW{1'b0}};
      spike <= 1'b0;
    end else if (step_valid) begin
      // 软复位：v_sat >= th >= 1，所以 v_sat - th ∈ [0, v_sat]，不会下溢
      v_out <= s_c ? (v_sat - th) : v_sat;
      spike <= s_c;
    end
    // step_valid=0：v_out / spike 保持（纯 IF，空闲不改变状态）
  end

endmodule
