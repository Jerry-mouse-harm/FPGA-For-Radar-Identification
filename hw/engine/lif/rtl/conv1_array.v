// Conv1 阵列（8 通道 × 128 位置，k=5，pad=2，T=16）—— LIF 第一层
//
// 干什么用的：
//   把前端每步的 128-bit 输入脉冲向量做 5 抽头卷积，每个输出位置/通道有自己的
//   LIF 神经元。训练端对应（src/models/snn_conv.py）：
//       a1[t,c,j] = b[c] + Σ_k W[c,0,k] · s_in[t, j+k-2]     // pad=2，边界补 0
//       (s1[t,c,j], v) = LIF(a1[t,c,j])                       // 纯 IF + 软复位
//   卷积的"脉冲 × 权重"在这里退化为**条件加**（脉冲是 0/1），没有乘法器。
//
// 架构：通道串行 + 位置分组串行 + 抽头串行（为什么不是全并行）
//   全并行 = 8×128 = 1024 个 LIF 更新单元，实测直接撑爆 20K 器件。
//   本设计利用两个正交的"互不依赖"：
//     · 各输出通道互不依赖 → 一次只算一个通道的全部 16 步；
//     · 各位置互不依赖     → 一次只算 PW=16 个位置（8 组依次扫），
//       扫完一组就把该组的膜电位清 0（LIF 初始态），所以只需 16 份膜电位。
//   资源（GW2AR-18，nextpnr 实测）：PW=64 时 LUT4 88% 布局失败；
//   PW=32 单层约 51%，但与 Conv2 级联后 91% 布局不收敛；
//   取 PW=16 把 lane 算术减半（代价是周期数再翻倍）。
//     · 膜电位 16×16 bit，LIF/卷积逻辑 16 份
//     · 输入帧/输出帧各 16×128 bit 环形缓存（装载后通道间反复用）
//   每通道算完把 16 个输出向量放进 out_ring，最后按 ch/step 顺序流式吐出。
//   （层间是"通道优先"顺序，下一级 Conv2 正好也按输入通道累加，天然吻合。）
//
// 周期预算（PW=16，G=N/PW=8 组）：
//   每 (通道, 位置组, 时间步)：5 个抽头周期（第 5 拍同时做 LIF 更新）
//   每通道：8 组 × (16 步 × 5 + 1 清膜电位) + 16 拍输出 = 664 拍
//   整帧： 16 拍装载 + 8 通道 × 664 = 5328 拍 ≈ 197 µs @27MHz
//
// 5 抽头怎么串行（每拍只读一个权重，权重广播到 16 条 lane）：
//   tap 0 : acc <= bias + (bit0 ? W0 : 0)
//   tap 1 : acc <= acc  + (bit1 ? W1 : 0)
//   tap 2 : acc <= acc  + (bit2 ? W2 : 0)
//   tap 3 : acc <= acc  + (bit3 ? W3 : 0)
//   tap 4 : x = acc + (bit4 ? W4 : 0)  → v 更新 / 判发 / 软复位 / 输出该位置 spike
//   bit_k = 位置 j 的窗口比特（j+k-2）：
//     · 全帧两侧补 2 个 0（pad=2）
//     · 组交界（如位置 31/32）必须能看到对方的样本，所以窗口统一从
//       补零后的完整帧 spk_pad 里按 g*PW 取 PW+4 位切片，不做"组内补零"。
//
// 权重 ROM：rtl/conv1_wrom.v（自动生成，三端口：权重/偏置/阈值）
//   addr_w = ch*5 + tap；addr_b = 40 + ch；addr_t = 48 + ch
//
// 输出顺序（冻结，判分台按这个查）：
//   ch=0 的 t=0..15，然后 ch=1 的 t=0..15 … ch=7 的 t=0..15
//   out_valid 共 128 拍；done 与最后一个 out_valid 同拍；busy 下一拍落。
//
// 端口：
//   clk/rst_n     : clk_eng / eng_rst_n（异步复位低有效）
//   in_valid      : 直接接 encode_frontend 的 step_valid（每帧 16 拍）
//   in_spike      : 接 spike_vec[127:0]；bit j = 位置 j
//   busy          : 装载 + 计算 + 输出期间为 1
//   done          : 一帧完成（与最后一个 out_valid 同拍，1 拍）
//   out_valid     : out_ch/out_step/out_spike 有效
//   out_ch        : 输出通道号 0..7
//   out_step      : 时间步 0..15
//   out_spike     : 该 (通道, 时间步) 的 128 路发放，bit j = 位置 j
module conv1_array #(
  parameter integer N  = 128,    // 输入位置数
  parameter integer T  = 16,     // 时间步数
  parameter integer C  = 8,      // 输出通道数
  parameter integer K  = 5,      // 卷积核长度
  parameter integer PW = 16,     // 并行位置数（要求 N % PW == 0，G=N/PW 组）
  parameter integer VW = 16,     // 膜电位位宽
  parameter integer XW = 16,     // 卷积和位宽
  parameter integer TW = 16      // 阈值/偏置位宽
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             in_valid,
  input  wire [N-1:0]     in_spike,
  output reg              busy,
  output reg              done,
  output reg              out_valid,
  output reg  [2:0]       out_ch,
  output reg  [3:0]       out_step,
  output reg  [N-1:0]     out_spike
);

  localparam [5:0] S_IDLE     = 6'd0;
  localparam [5:0] S_LOAD     = 6'd1;
  localparam [5:0] S_CH_START = 6'd2;
  localparam [5:0] S_TAP      = 6'd3;
  localparam [5:0] S_EMIT     = 6'd4;
  localparam [5:0] S_GRP_START= 6'd5;   // 组间：清膜电位（位置互不依赖）

  localparam integer G  = N / PW;                // 位置组数
  localparam integer GW = (G > 2) ? $clog2(G) : 1;  // 组计数位宽（PW=16→3 位，PW=8→4 位）
  localparam integer AW = (XW > VW) ? XW : VW;   // 加法器基础宽度
  localparam signed [VW-1:0] VMAX = {1'b0, {(VW-1){1'b1}}};
  localparam signed [VW-1:0] VMIN = {1'b1, {(VW-1){1'b0}}};
  localparam signed [XW-1:0] ZEROX = {XW{1'b0}};

  reg [5:0] state;
  reg [2:0] ch_q;
  reg [GW-1:0] g_q;               // 位置组 0..G-1（位宽随 PW 自适应）
  reg [3:0] step_q;
  reg [2:0] tap_q;
  reg [3:0] ld_q;
  reg [3:0] emit_cnt;

  // ---------------- 环形帧缓存（用旋转代替 16:1 大 mux）----------------
  // 32 位 Gowin 器件放不下 4 个 128bit×16 的 16:1 读写 mux（实测 LUT4 88%，
  // 布局失败）。这里把帧缓存做成"整体旋转一个字"的移位环：每步只做纯连线
  // 旋转（0 LUT），永远只读写头部/固定槽位。
  //   spk_ring : 16 × 128 bit。装载时写最高字后下旋；每步 tap4 下旋一次。
  //              对齐：16 步 × G 组 = 16G，加上 16 拍输出，都是 16 的倍数。
  //   out_ring : 16 × 128 bit。组 g 在 tap4 写第 g 个 PW 位置段到"最高字"
  //              （tap0 已把当前步的字转到那里）；emit 时从头部顺序读。
  reg [T*N-1:0] spk_ring;
  reg [T*N-1:0] out_ring;

  wire [N-1:0] spk_head = spk_ring[0 +: N];   // 当前步输入向量
  wire [N-1:0] out_head = out_ring[0 +: N];   // emit 当前步的完整 128 bit

  // 当前步的输入向量（寄存器化，避免在 64 条 lane 上摊一个 16:1 大 mux）
  reg [N-1:0] cur_spk;

  // 当前组的膜电位（组间清 0；位置互不依赖，不需要常驻全部 128 个）
  reg signed [VW-1:0] v [0:PW-1];
  // 5 抽头串行累加器（进入每个 (组,步) 时重装）
  reg signed [XW-1:0] acc [0:PW-1];

  // 下旋一个字的两个通用式子（纯连线）
  //   down(x)      = {x[0+:N], x[T*N-1:N]}
  //   写最高字覆盖 = {din, x[T*N-1:N]}

  reg signed [TW-1:0] bias_q;
  reg signed [TW-1:0] th_q;

  // ---------------- 权重 ROM ----------------
  wire signed [15:0] w_rom, b_rom, t_rom;
  wire [5:0] rom_addr_w = ch_q * K + tap_q;
  wire [5:0] rom_addr_b = C * K + ch_q;
  wire [5:0] rom_addr_t = C * K + C + ch_q;

  conv1_wrom u_rom (
    .addr_w (rom_addr_w),
    .addr_b (rom_addr_b),
    .addr_t (rom_addr_t),
    .dout_w (w_rom),
    .dout_b (b_rom),
    .dout_t (t_rom)
  );

  // ---------------- 位置窗口 ----------------
  // 全帧两侧各补 2 个 0，再按组取 PW+4 位切片：
  //   组 g 的 lane l 对应位置 p = g*PW + l，切片起点在 spk_pad 的 p
  //   （pad 的索引 p 就是位置 p-2）。组交界自然共享相邻样本。
  wire [N+3:0] spk_pad = {2'b00, cur_spk, 2'b00};
  wire [PW+3:0] win    = spk_pad[g_q*PW +: PW+4];

  wire [PW-1:0] spike_next_v;     // 本拍（tap=4）64 条 lane 的判决结果

  genvar l;
  generate
    for (l = 0; l < PW; l = l + 1) begin : g_lane
      // 本 lane 的 5-bit 窗口和当前抽头比特
      wire [4:0] w5   = win[l +: 5];
      wire       wbit = (tap_q < K) ? w5[tap_q] : 1'b0;

      // 条件加：脉冲=1 才把权重加上（两个操作数都必须是 signed）
      wire signed [XW-1:0] wsel = wbit ? w_rom : ZEROX;

      // tap=4 时的卷积和（acc 里已经是 tap0..3 的和）
      wire signed [XW-1:0] x_final = acc[l] + wsel;

      // ---- LIF 更新（与 rtl/lif_neuron.v 同一套规则）----
      wire signed [VW-1:0] v_cur = v[l];

      // 先符号扩展再相加，防止"表达式按操作数宽度算完再扩位"丢进位
      wire signed [AW:0] vsum = {{(AW+1-VW){v_cur[VW-1]}}, v_cur}
                              + {{(AW+1-XW){x_final[XW-1]}}, x_final};

      wire signed [VW-1:0] v_sat = (vsum > VMAX) ? VMAX :
                                   (vsum < VMIN) ? VMIN : vsum[VW-1:0];
      wire s_next = (v_sat >= th_q);                 // >=，不是 >
      wire signed [VW-1:0] v_new = s_next ? (v_sat - th_q) : v_sat;

      assign spike_next_v[l] = s_next;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          v[l]   <= {VW{1'b0}};
          acc[l] <= {XW{1'b0}};
        end else if (state == S_CH_START || state == S_GRP_START) begin
          // 新通道 / 新位置组：膜电位从 0 开始（LIF 初始状态）
          v[l] <= {VW{1'b0}};
        end else if (state == S_TAP) begin
          if (tap_q == 3'd0)
            acc[l] <= bias_q + wsel;                 // tap0：偏置 + 第一个权重
          else if (tap_q < K-1)
            acc[l] <= acc[l] + wsel;                 // tap1..3：累加
          // tap4：acc 不再更新，x_final 组合得到完整卷积和

          if (tap_q == K-1) v[l] <= v_new;
        end
      end
    end
  endgenerate

  // ---------------- 主状态机 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      busy      <= 1'b0;
      done      <= 1'b0;
      out_valid <= 1'b0;
      out_ch    <= 3'd0;
      out_step  <= 4'd0;
      out_spike <= {N{1'b0}};
      ch_q      <= 3'd0;
      g_q       <= {GW{1'b0}};
      step_q    <= 4'd0;
      tap_q     <= 3'd0;
      ld_q      <= 4'd0;
      emit_cnt  <= 4'd0;
      cur_spk   <= {N{1'b0}};
      bias_q    <= {TW{1'b0}};
      th_q      <= {TW{1'b0}};
      spk_ring <= {T*N{1'b0}};
      out_ring <= {T*N{1'b0}};
    end else begin
      done      <= 1'b0;        // 默认单拍脉冲
      out_valid <= 1'b0;

      case (state)
        // ------------------------------------------------------------
        S_IDLE: begin
          if (in_valid) begin
            // 写最高字 + 整个环下旋一个字；16 次装载后第 i 步正好落在第 i 槽
            spk_ring <= {in_spike, spk_ring[T*N-1 : N]};
            ld_q     <= 4'd1;
            busy     <= 1'b1;
            state    <= S_LOAD;
          end
        end

        // ------------------------------------------------------------
        // 收满 T 个步向量后开始计算；中途 in_valid 有空洞也没关系
        S_LOAD: begin
          if (in_valid) begin
            spk_ring <= {in_spike, spk_ring[T*N-1 : N]};
            if (ld_q == T-1) begin
              ch_q  <= 3'd0;
              state <= S_CH_START;
            end else begin
              ld_q <= ld_q + 1'b1;
            end
          end
        end

        // ------------------------------------------------------------
        // 每个通道开始：装偏置/阈值（ROM 组合读），清膜电位，指向第 0 步
        S_CH_START: begin
          bias_q  <= b_rom;
          th_q    <= t_rom;
          g_q     <= {GW{1'b0}};
          step_q  <= 4'd0;
          tap_q   <= 3'd0;
          cur_spk <= spk_head;
          state   <= S_TAP;
        end

        // ------------------------------------------------------------
        // 组间：清膜电位（位置组互不依赖，旧组的 v 不再需要）
        S_GRP_START: begin
          state <= S_TAP;
        end

        // ------------------------------------------------------------
        // 5 抽头串行；第 5 拍更新膜电位并输出该 (通道,步) 的 spike 半向量
        S_TAP: begin
          if (tap_q == 3'd0) begin
            // 输出环下旋：本步对应的字被转到最高槽，tap4 把结果合并进去
            out_ring <= {out_ring[0 +: N], out_ring[T*N-1 : N]};
            tap_q    <= tap_q + 1'b1;
          end else if (tap_q == K-1) begin
            // LIF 的 s_next 在 tap4 这个沿被寄存器采样，写入最高字的第 g 个
            // 位置段（32 bit）；4 组都写完后正好拼成完整 128 bit
            out_ring[T*N-N + g_q*PW +: PW] <= spike_next_v;

            // 输入环下旋，同时预取"旋转后的头部"= 下一步的输入向量
            // （NBA 读的是旋转前的值，所以取第 1 个字）
            spk_ring <= {spk_ring[0 +: N], spk_ring[T*N-1 : N]};
            cur_spk  <= spk_ring[N +: N];

            if (step_q == T-1) begin
              if (g_q != G-1) begin
                // 本组算完，清膜电位后从第 0 步扫下一组
                g_q     <= g_q + 1'b1;
                step_q  <= 4'd0;
                tap_q   <= 3'd0;
                state   <= S_GRP_START;
              end else begin
                // 所有位置组都算完，开始按 ch/step 顺序输出
                emit_cnt <= 4'd0;
                state    <= S_EMIT;
              end
            end else begin
              step_q  <= step_q + 1'b1;
              tap_q   <= 3'd0;
            end
          end else begin
            tap_q <= tap_q + 1'b1;
          end
        end

        // ------------------------------------------------------------
        // 输出：ch 优先、step 次之；各组位置段已拼成完整 128 bit
        S_EMIT: begin
          out_valid <= 1'b1;
          out_ch    <= ch_q;
          out_step  <= emit_cnt;
          out_spike <= out_head;                  // 头部就是 emit_cnt 那一步
          out_ring  <= {out_ring[0 +: N], out_ring[T*N-1 : N]};

          if (emit_cnt == T-1) begin
            if (ch_q == C-1) begin
              // 只有最后一个通道的最后一拍才 done
              done  <= 1'b1;        // 与最后一个 out_valid 同拍
              busy  <= 1'b0;
              ch_q  <= 3'd0;
              state <= S_IDLE;
            end else begin
              ch_q  <= ch_q + 1'b1;
              state <= S_CH_START;
            end
          end else begin
            emit_cnt <= emit_cnt + 1'b1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
