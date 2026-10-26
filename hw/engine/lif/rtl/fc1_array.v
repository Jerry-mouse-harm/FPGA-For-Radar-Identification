// FC1 阵列（Conv2 输出 16 通道 × 64 位置 → OR 池化 64→32 → 512→32 全连接 + LIF3）
//
// 干什么用的：
//   Conv2 输出每帧 16 通道 × 16 步 × 64 位置。与 Conv2 输入端一样，先做 OR 池化
//   （相邻两位相或）得到 64→32 位置，再按 PyTorch flatten(1) 的顺序展平成 512 维，
//   送进 32 个 FC1 神经元。训练端对应（src/models/snn_conv.py）：
//       p[t,o,j] = s2[t,o,2j] | s2[t,o,2j+1]                    // MaxPool(2) on 0/1 = OR
//       c        = o*32 + j                                    // Flatten
//       a3[t,r]  = B1[r] + Σ_c W1[r,c] · p[t, o=c>>5, j=c&31]
//       (s3[t,r], v) = LIF(a3[t,r])                            // 纯 IF + 软复位
//   读出层（Linear 32→5 + argmax）在 rtl/readout.v，单独一个模块。
//
// 架构：LP 条 lane（默认 8）× 512 个输入串行；32 个神经元分 NG=NR/LP 趟扫
//   · 输入帧缓存 in_mem：256 字 × 32 bit（{通道,步} 寻址），装载期写、计算期读。
//   · 权重 ROM：512 地址 × 32 神经元 × int8 = 8 个 BSRAM 银行，同步读 + 1 拍流水。
//   · 每个时间步：同一 512 输入扫 NG 趟，每趟 LP 条 lane 各做一次"条件加"。
//     FC1 的扇入 512 是 Conv1 的 4 倍、Conv2 的 12.8 倍，所以神经元必须并行：
//     若完全串行（一次一个神经元），单帧要 16×512×32 ≈ 26 万拍（≈9.7ms）。
//     LP=32（NG=1）单帧 ≈ 8.5k 拍，但四层级联时 LUT4 站点 + 宽 mux 折算站点
//     超过 GW2AR-18 的 20736 个站点；LP=16（NG=2）单帧 ≈ 16.7k 拍，实测仍
//     布局失败（等效 ~117%）；**LP=8（NG=4）单帧 ≈ 33.2k 拍（≈1.22ms），
//     四层链路 LUT4 51% 布局通过**。LP 是纯并行度参数，不改任何算术。
//   · 输入比特用 32 位移位寄存器逐位取出（一个输入字管 32 拍），不做 32:1 mux。
//   · 偏置/阈值是每神经元常量（fc1_wrom 里直接 assign），按 g 选常量切片。
//   · 膜电位按组存 NG 个 bank（v[0:NG-1]），算哪组读写哪个 bank。
//
// 时序（与 Conv2 输出直接级联）：
//   装载：in_valid 连续 256 拍（o=0..15，每通道 t=0..15），第一拍兼作启动。
//   计算：每趟 1 拍 S_STEP_START（换组时重新扫输入）+ 512 拍 S_ACC + 1 拍 S_LIF。
//        第 512 拍把最后一项累进 acc；S_LIF 拍完成膜电位更新并（末组时）给出
//        spk_valid/spk_vec。
//   结束：第 16 步末组的 spk_valid 那拍 frame_done=1，busy 同拍落，模块回 IDLE。
//   16 步之间**没有**清膜电位（LIF 状态跨步保持）；每帧开始时清一次。
//
// 权重 ROM：rtl/fc1_wrom.v（自动生成）
//   addr_w = c（0..511）；dout_w[8*r +: 8] = W1[r][c]
//   dout_b / dout_t 是 32 个 16 bit 常量
//
// 端口：
//   clk/rst_n     : clk_eng / eng_rst_n（异步复位低有效）
//   in_valid      : 接 conv2_array 的 out_valid（每帧 256 拍）
//   in_ch/in_step : 接 conv2 的 out_ch/out_step
//   in_spike      : 接 conv2 的 out_spike；bit j = 位置 j（64 位）
//   busy          : 装载 + 计算期间为 1
//   frame_start   : 每帧计算开始时 1 拍（给 readout 清累加器）
//   spk_valid     : 每个时间步结束 1 拍，共 T 拍
//   spk_vec       : 该时间步的 32 路 LIF3 发放（bit r = 神经元 r）
//   frame_done    : 第 16 步的 spk_valid 同拍 1 拍
module fc1_array #(
  parameter integer NPIN = 64,   // Conv2 输出位置数
  parameter integer NP   = 32,   // 池化后位置数（要求 NP 是 2 的幂）
  parameter integer CI   = 16,   // Conv2 输出通道数
  parameter integer T    = 16,   // 时间步数
  parameter integer NR   = 32,   // FC1 神经元数
  parameter integer LP   = 8,    // 并行 lane 数（需整除 NR；LP=NR 即单趟全并行）
  parameter integer VW   = 16,   // 膜电位位宽
  parameter integer XW   = 16,   // 加权和位宽（真实权重实测 |x| ≤ 1755，16 位足够）
  parameter integer TW   = 16    // 阈值/偏置位宽
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             in_valid,
  input  wire [3:0]       in_ch,
  input  wire [3:0]       in_step,
  input  wire [NPIN-1:0]  in_spike,
  output reg              busy,
  output reg              frame_start,
  output reg              spk_valid,
  output reg  [NR-1:0]    spk_vec,
  output reg              frame_done
);

  localparam [2:0] S_IDLE       = 3'd0;
  localparam [2:0] S_LOAD       = 3'd1;
  localparam [2:0] S_STEP_START = 3'd2;
  localparam [2:0] S_ACC        = 3'd3;
  localparam [2:0] S_LIF        = 3'd4;   // 步末：acc 已含完整电流，做膜电位更新

  localparam integer NIN   = CI * NP;               // 512 个输入
  localparam integer NW    = CI * T;                // 输入缓存字数 256
  localparam integer MADDR = $clog2(NW);            // 8
  localparam integer WA    = $clog2(NIN);           // 9
  localparam integer LB    = $clog2(NP);            // 5（一个输入字的位数）
  localparam integer AW    = (XW > VW) ? XW : VW;   // 加法器基础宽度
  localparam signed [VW-1:0] VMAX = {1'b0, {(VW-1){1'b1}}};
  localparam signed [VW-1:0] VMIN = {1'b1, {(VW-1){1'b0}}};
  localparam signed [XW-1:0] ZEROX = {XW{1'b0}};

  reg [2:0]  state;
  reg [7:0]  ld_cnt;                // 装载计数 0..NW-1
  reg [3:0]  step_q;                // 时间步 0..T-1
  reg [WA-1:0] c_q;                 // 输入序号 0..NIN-1
  reg [WA-1:0] w_addr;              // 权重 ROM 地址（提前一拍）
  reg [MADDR-1:0] rd_addr;          // 输入缓存读地址
  reg [NP-1:0] bit_sr;              // 当前输入字的剩余比特

  // ---------------- 输入帧缓存（OR 池化后）----------------
  // 写：装载期按 {in_ch,in_step} 写入；读：计算期按 {输入通道, step_q} 同步读。
  // 写口单独一个同步块（不带复位）：和主 FSM 的异步复位混在一起会阻止存储器推断。
  reg [NP-1:0] in_mem [0:NW-1];
  reg [NP-1:0] rd_data;

  wire [NP-1:0] pooled;
  genvar p;
  generate
    for (p = 0; p < NP; p = p + 1) begin : g_pool
      assign pooled[p] = in_spike[2*p] | in_spike[2*p+1];
    end
  endgenerate

  wire wr_en = ((state == S_IDLE) || (state == S_LOAD)) && in_valid;
  always @(posedge clk)
    if (wr_en) in_mem[{in_ch, in_step}] <= pooled;

  always @(posedge clk)
    rd_data <= in_mem[rd_addr];

  // 当前拍要用的输入比特：
  //   每个 32-bit 字管 32 拍。字内第 0 拍直接用 rd_data[0]，其余拍用移位寄存器。
  wire in_bit = (c_q[LB-1:0] == 0) ? rd_data[0] : bit_sr[0];

  // ---------------- 权重 ROM ----------------
  wire [255:0]       w_rom;         // 32 × int8
  wire signed [511:0] b_const;      // 32 × int16
  wire signed [511:0] th_const;

  fc1_wrom u_rom (
    .clk    (clk),
    .addr_w (w_addr),
    .dout_w (w_rom),
    .dout_b (b_const),
    .dout_t (th_const)
  );

  // ---------------- LP 条 lane（每条负责 NG 个神经元，按 g_q 选）----------------
  localparam integer NG = NR / LP;   // 每步扫几趟（2 趟 = 16 lane × 2 组）

  wire [LP-1:0] spike_next_v;
  reg  [3:0]    g_q;                 // 当前趟 0..NG-1
  integer       gg;

  genvar l;
  generate
    for (l = 0; l < LP; l = l + 1) begin : g_lane
      reg signed [VW-1:0] v [0:NG-1];  // 膜电位按组分 bank（跨时间步保持）
      reg signed [XW-1:0] acc;

      // 本趟负责的神经元号：r = g_q*LP + l（l 是常量 → 常量偏移 + 2:1 mux）
      wire [4:0] r_sel = g_q * LP + l;

      wire signed [7:0] w_byte = w_rom[8*r_sel +: 8];
      wire signed [TW-1:0] b_l = b_const[TW*r_sel +: TW];
      wire signed [TW-1:0] th_l = th_const[TW*r_sel +: TW];

      // 条件加：脉冲=1 才把权重加上（先符号扩展到 XW，两个操作数都必须是 signed）
      wire signed [XW-1:0] wsel = in_bit
          ? {{(XW-8){w_byte[7]}}, w_byte} : ZEROX;

      // 第 512 拍把最后一个权重也写进 acc，下一拍 S_LIF 里 acc 即完整输入电流。
      // 这样每条 lane 只有 3 个加法器（acc 累加 / v+x / 软复位减阈值），
      // 不再为最后一步单独做一次 "acc+wsel" 的重复加法（省 32×16 个 ALU）。

      // ---- LIF 更新（与 lif_neuron / conv1_array / conv2_array 同一套规则）----
      wire signed [VW-1:0] v_cur = v[g_q];

      // 先符号扩展再相加，防止"表达式按操作数宽度算完再扩位"丢进位
      wire signed [AW:0] vsum = {{(AW+1-VW){v_cur[VW-1]}}, v_cur}
                              + {{(AW+1-XW){acc[XW-1]}}, acc};

      wire signed [VW-1:0] v_sat = (vsum > VMAX) ? VMAX :
                                   (vsum < VMIN) ? VMIN : vsum[VW-1:0];
      wire s_next = (v_sat >= th_l);                // >=，不是 >
      wire signed [VW-1:0] v_new = s_next ? (v_sat - th_l) : v_sat;

      assign spike_next_v[l] = s_next;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (gg = 0; gg < NG; gg = gg + 1) v[gg] <= {VW{1'b0}};
          acc <= {XW{1'b0}};
        end else if (state == S_STEP_START && step_q == 0 && g_q == 0) begin
          // 每帧第一步（第一趟）：清所有 bank 的膜电位（16 步之间保持，纯 IF 没有泄漏）
          for (gg = 0; gg < NG; gg = gg + 1) v[gg] <= {VW{1'b0}};
        end else if (state == S_ACC) begin
          if (c_q == 0)
            acc <= b_l + wsel;                      // 第一步：偏置 + 第一个权重
          else
            acc <= acc + wsel;                      // 含 c=NIN-1：最后一项也进 acc
        end else if (state == S_LIF) begin
          v[g_q] <= v_new;                          // acc 已是完整输入电流
        end
      end
    end
  endgenerate

  // ---------------- 主状态机 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      frame_start<= 1'b0;
      spk_valid  <= 1'b0;
      spk_vec    <= {NR{1'b0}};
      frame_done <= 1'b0;
      ld_cnt     <= 8'd0;
      step_q     <= 4'd0;
      g_q        <= 4'd0;
      c_q        <= {WA{1'b0}};
      w_addr     <= {WA{1'b0}};
      rd_addr    <= {MADDR{1'b0}};
      bit_sr     <= {NP{1'b0}};
    end else begin
      frame_start <= 1'b0;        // 默认单拍脉冲
      spk_valid   <= 1'b0;
      frame_done  <= 1'b0;

      case (state)
        // ------------------------------------------------------------
        S_IDLE: begin
          if (in_valid) begin
            ld_cnt <= 8'd1;
            busy   <= 1'b1;
            state  <= S_LOAD;
          end
        end

        // ------------------------------------------------------------
        // 收满 CI*T 个 (通道,步) 向量后开始计算；中途 in_valid 有空洞也没关系
        S_LOAD: begin
          if (in_valid) begin
            if (ld_cnt == NW-1) begin
              step_q <= 4'd0;
              g_q    <= 4'd0;
              c_q    <= {WA{1'b0}};
              w_addr <= {WA{1'b0}};
              state  <= S_STEP_START;
            end else begin
              ld_cnt <= ld_cnt + 1'b1;
            end
          end
        end

        // ------------------------------------------------------------
        // 每趟开始：预取 (输入通道 0, 本步) 的字 + 权重地址（下一拍可用）
        // 权重 ROM 是同步读 1 拍延迟：本拍 addr_w 还是上一趟趟尾预置的 0，
        // 沿上把 W[0] 读进 dout_w 供第一个 S_ACC 拍用；本拍把地址预置成 1。
        // 同一步的 NG 趟扫同一份输入，所以每趟都要重新把读地址拨回 step_q。
        S_STEP_START: begin
          if (step_q == 0 && g_q == 0) frame_start <= 1'b1;
          rd_addr <= step_q;                    // 高 4 位是通道号，首通道 = 0
          w_addr  <= {{(WA-1){1'b0}}, 1'b1};
          c_q     <= {WA{1'b0}};
          state   <= S_ACC;
        end

        // ------------------------------------------------------------
        // 512 拍串行扫输入；第 512 拍把最后一项也累进 acc，然后转 S_LIF
        S_ACC: begin
          // ---- 移位寄存器：新字装载（字内第 0 拍）或右移 ----
          // 本拍用 bit0（c 低位=0 时直接取 rd_data[0]，否则取 bit_sr[0]），
          // 所以装载/右移都把下一位放到 bit_sr[0]：切片必须是 [NP-1:1]。
          if (c_q[LB-1:0] == 0)
            bit_sr <= {1'b0, rd_data[NP-1:1]};
          else
            bit_sr <= {1'b0, bit_sr[NP-1:1]};

          if (c_q == NIN-1) begin
            c_q    <= {WA{1'b0}};
            w_addr <= {WA{1'b0}};
            // 末趟：预取下一步 (通道 0, step+1) 的字；非末趟：回到本步首通道，
            // 下一趟重新扫同一份输入。
            rd_addr <= (g_q == NG-1)
                     ? ((step_q == T-1) ? {MADDR{1'b0}} : {4'd0, step_q + 4'd1})
                     : {4'd0, step_q};
            state  <= S_LIF;
          end else begin
            c_q    <= c_q + 1'b1;
            w_addr <= w_addr + 1'b1;
            // 下个通道的同一时间步：读延迟 1 拍，所以在本字倒数第二拍切地址
            // （c=31 沿读进 rd_data 的是下一通道，c=32 正好可用）
            if (c_q[LB-1:0] == NP-2)
              rd_addr <= {c_q[WA-1:LB] + 1'b1, step_q};
          end
        end

        // ------------------------------------------------------------
        // 趟末：acc 已是本组 LP 个神经元的完整输入电流，本拍沿写入 v / spk_vec 切片
        // 末趟才发 spk_valid（一个时间步对下游只报一次，32 位一次给全）。
        S_LIF: begin
          spk_vec[g_q*LP +: LP] <= spike_next_v;
          if (g_q == NG-1) begin
            spk_valid <= 1'b1;
            if (step_q == T-1) begin
              frame_done <= 1'b1;
              busy       <= 1'b0;
              step_q     <= 4'd0;
              g_q        <= 4'd0;
              state      <= S_IDLE;
            end else begin
              step_q <= step_q + 1'b1;
              g_q    <= 4'd0;
              state  <= S_STEP_START;
            end
          end else begin
            g_q   <= g_q + 1'b1;
            state <= S_STEP_START;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
