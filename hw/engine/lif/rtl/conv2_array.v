// Conv2 阵列（8 输入通道 → 16 输出通道，64 位置，k=5，pad=2，T=16）—— LIF 第二层
//
// 干什么用的：
//   Conv1 输出的每个 (通道, 时间步) 是 128 位发放向量；先做 OR 池化（相邻两位相或）
//   得到 64 位置，再做 8→16 通道的 5 抽头卷积 + LIF。训练端对应（src/models/snn_conv.py）：
//       p[t,i,j] = s1[t,i,2j] | s1[t,i,2j+1]                  // MaxPool(2) 作用在 0/1 上 = OR
//       a2[t,o,j] = b[o] + Σ_i Σ_k W[o,i,k] · p[t,i,j+k-2]    // pad=2，越界补 0
//       (s2[t,o,j], v) = LIF(a2[t,o,j])                       // 纯 IF + 软复位
//   与 Conv1 一样，脉冲×权重退化为**条件加**，没有乘法器。
//
// 架构：输出通道串行 + 位置分组串行（PW=16，G=4）+ 输入通道/抽头串行
//   · 输入帧缓存 in_mem：8 输入通道 × 16 步 × 64 位 = 128 字 × 64 bit。
//     装载期写、计算期读，读口每 (输入通道, 时间步) 读一次，5 个抽头共用。
//     （用同步读的存储器，综合时推断 BSRAM；组合读 128:1 mux 会吃掉上万 LUT。）
//   · 权重 ROM：640 项（16×8×5），同步读 + 1 拍流水。
//   · 每输出通道只保留一组 16 个膜电位；位置组间互不依赖，换组时清 0。
//   · 输出环 out_ring：16 步 × 64 位，每组把 16 位位置段写进"最高字"，
//     四组拼成完整 64 位；每步整体旋转（纯连线，0 LUT）。
//
// 周期预算（PW=16，G=4，CI=8，K=5）：
//   每 (输出通道, 位置组, 时间步)：CI×K = 40 拍（第 40 拍同时做 LIF 更新）
//   每输出通道：1 (装偏置/阈值) + 4×(1 清膜电位 + 16×40) + 16 (输出) = 2581 拍
//   整帧：128 装载 + 16 × 2581 = 41424 拍 ≈ 1534 µs @27MHz
//   （比 Conv1 的 197 µs 长，主要因为输入通道 8×、输出通道 2×、抽头 5×；
//     后续可做输入通道并行 / 输出通道并行来压缩，先用串行版打通数值通路。）
//
// 输入接口与 Conv1 输出完全一致（可直接级联）：
//   in_valid / in_ch[2:0] / in_step[3:0] / in_spike[127:0]，每帧 8×16 = 128 拍。
//
// 输出顺序（冻结，判分台按这个查）：
//   o=0 的 t=0..15，然后 o=1 的 t=0..15 … o=15 的 t=0..15
//   out_valid 共 256 拍；done 与最后一个 out_valid 同拍；busy 下一拍落。
//
// 端口：
//   clk/rst_n     : clk_eng / eng_rst_n（异步复位低有效）
//   busy          : 装载 + 计算 + 输出期间为 1
//   done          : 一帧完成（与最后一个 out_valid 同拍，1 拍）
//   out_valid     : out_ch/out_step/out_spike 有效
//   out_ch        : 输出通道号 0..15
//   out_step      : 时间步 0..15
//   out_spike     : 该 (通道, 时间步) 的 64 路发放，bit j = 位置 j
module conv2_array #(
  parameter integer NIN = 128,   // 输入位置数（Conv1 输出）
  parameter integer NP  = 64,    // 池化后位置数
  parameter integer T   = 16,    // 时间步数
  parameter integer CI  = 8,     // 输入通道数
  parameter integer CO  = 16,    // 输出通道数
  parameter integer K   = 5,     // 卷积核长度
  parameter integer PW  = 16,    // 并行位置数（要求 NP % PW == 0，G=NP/PW 组）
  parameter integer VW  = 16,    // 膜电位位宽
  parameter integer XW  = 16,    // 卷积和位宽（扇入 40×127+偏置，14 位就够，留 16 统一）
  parameter integer TW  = 16     // 阈值/偏置位宽
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             in_valid,
  input  wire [2:0]       in_ch,
  input  wire [3:0]       in_step,
  input  wire [NIN-1:0]   in_spike,
  output reg              busy,
  output reg              done,
  output reg              out_valid,
  output reg  [3:0]       out_ch,
  output reg  [3:0]       out_step,
  output reg  [NP-1:0]    out_spike
);

  localparam [2:0] S_IDLE      = 3'd0;
  localparam [2:0] S_LOAD      = 3'd1;
  localparam [2:0] S_OC_START  = 3'd2;
  localparam [2:0] S_GRP_START = 3'd3;
  localparam [2:0] S_ACC       = 3'd4;
  localparam [2:0] S_EMIT      = 3'd5;

  localparam integer G      = NP / PW;              // 位置组数
  localparam integer GW     = (G > 2) ? $clog2(G) : 1;  // 组计数位宽
  localparam integer NW     = CI * T;               // 输入缓存字数
  localparam integer MADDR  = $clog2(NW);           // 7
  localparam integer WA     = $clog2(CO * CI * K);  // 10
  localparam integer AW     = (XW > VW) ? XW : VW;  // 加法器基础宽度
  localparam signed [VW-1:0] VMAX = {1'b0, {(VW-1){1'b1}}};
  localparam signed [VW-1:0] VMIN = {1'b1, {(VW-1){1'b0}}};
  localparam signed [XW-1:0] ZEROX = {XW{1'b0}};

  reg [2:0]  state;
  reg [3:0]  oc_q;                // 输出通道 0..CO-1
  reg [GW-1:0] g_q;               // 位置组 0..G-1（位宽随 PW 自适应）
  reg [3:0]  step_q;
  reg [2:0]  ic_q;                // 输入通道 0..CI-1
  reg [2:0]  tap_q;
  reg [MADDR-1:0] ld_cnt;
  reg [3:0]  emit_cnt;

  // ---------------- 输入帧缓存（OR 池化后）----------------
  // 写：装载期按 {in_ch,in_step} 写入；读：计算期按 {ic_q,step_q} 同步读。
  reg [NP-1:0] in_mem [0:NW-1];
  reg [MADDR-1:0] rd_addr;
  reg [NP-1:0]    rd_data;
  always @(posedge clk)
    rd_data <= in_mem[rd_addr];

  wire [NP-1:0] pooled;
  genvar p;
  generate
    for (p = 0; p < NP; p = p + 1) begin : g_pool
      assign pooled[p] = in_spike[2*p] | in_spike[2*p+1];
    end
  endgenerate

  // 写口单独一个同步块（不带复位）：和主 FSM 的异步复位混在一起会阻止
  // 存储器推断，整块 128×64 会被摊成 8192 个 DFFE（实测 yosys 警告）。
  wire wr_en = ((state == S_IDLE) || (state == S_LOAD)) && in_valid;
  always @(posedge clk)
    if (wr_en) in_mem[{in_ch, in_step}] <= pooled;

  // ---------------- 权重 ROM ----------------
  wire signed [15:0] w_rom, b_rom, t_rom;
  reg  [WA-1:0] rom_addr_w;

  conv2_wrom u_rom (
    .clk    (clk),
    .addr_w (rom_addr_w),
    .addr_b (oc_q[3:0]),
    .addr_t (oc_q[3:0]),
    .dout_w (w_rom),
    .dout_b (b_rom),
    .dout_t (t_rom)
  );

  // 权重地址 = base + (子步序号)，子步序号 = ic*K + tap（40 个子步顺序扫描 40 项权重）。
  // 同步 ROM 有 1 拍读延迟，所以地址必须"提前一拍"：本拍送 addr(n+1)，
  // 下一拍 ROM 输出的正好是第 n+1 个子步要用的权重。
  wire [WA-1:0] w_base_oc   = oc_q * (CI * K);
  wire [WA-1:0] w_last_addr = w_base_oc + (CI * K - 1);   // 第 39 个子步的地址

  // ---------------- 位置窗口 ----------------
  // tap0 用本拍刚读出的 rd_data；tap1..4 用 tap0 时锁存的 cur_vec。
  reg  [NP-1:0] cur_vec;
  wire [NP-1:0] vec_now = (tap_q == 3'd0) ? rd_data : cur_vec;

  // 全帧两侧各补 2 个 0，再按组取 PW+4 位切片（组交界自然共享相邻位置）
  wire [NP+3:0] vec_pad = {2'b00, vec_now, 2'b00};
  wire [PW+3:0] win     = vec_pad[g_q*PW +: PW+4];

  // ---------------- 膜电位 / 累加器 ----------------
  reg signed [VW-1:0] v   [0:PW-1];
  reg signed [XW-1:0] acc [0:PW-1];
  reg signed [TW-1:0] bias_q;
  reg signed [TW-1:0] th_q;

  wire [PW-1:0] spike_next_v;
  wire last_sub = (ic_q == CI-1) && (tap_q == K-1);

  genvar l;
  generate
    for (l = 0; l < PW; l = l + 1) begin : g_lane
      wire [4:0] w5   = win[l +: 5];
      wire       wbit = w5[tap_q];

      wire signed [XW-1:0] wsel = wbit ? w_rom[XW-1:0] : ZEROX;

      // 本拍卷积和（last_sub 时 acc 里已经含前面所有输入通道/抽头的和）
      wire signed [XW-1:0] x_final = acc[l] + wsel;

      // ---- LIF 更新（与 lif_neuron / conv1_array 同一套规则）----
      wire signed [VW-1:0] v_cur = v[l];

      // 先符号扩展再相加，防止表达式按操作数宽度算完再扩位丢进位
      wire signed [AW:0] vsum = {{(AW+1-VW){v_cur[VW-1]}}, v_cur}
                              + {{(AW+1-XW){x_final[XW-1]}}, x_final};

      wire signed [VW-1:0] v_sat = (vsum > VMAX) ? VMAX :
                                   (vsum < VMIN) ? VMIN : vsum[VW-1:0];
      wire s_next = (v_sat >= th_q);
      wire signed [VW-1:0] v_new = s_next ? (v_sat - th_q) : v_sat;

      assign spike_next_v[l] = s_next;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          v[l]   <= {VW{1'b0}};
          acc[l] <= {XW{1'b0}};
        end else if (state == S_GRP_START) begin
          // 新位置组：膜电位从 0 开始（LIF 初始状态）
          v[l] <= {VW{1'b0}};
        end else if (state == S_ACC) begin
          if (ic_q == 3'd0 && tap_q == 3'd0)
            acc[l] <= bias_q + wsel;              // 每步第一个抽头：偏置 + 权重
          else if (!last_sub)
            acc[l] <= acc[l] + wsel;              // 其余抽头累加
          // last_sub：acc 不再更新，x_final 组合得到完整卷积和

          if (last_sub) v[l] <= v_new;
        end
      end
    end
  endgenerate

  // ---------------- 输出环 ----------------
  reg [T*NP-1:0] out_ring;
  wire [NP-1:0]  out_head = out_ring[0 +: NP];

  // ---------------- 主状态机 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      done       <= 1'b0;
      out_valid  <= 1'b0;
      out_ch     <= 4'd0;
      out_step   <= 4'd0;
      out_spike  <= {NP{1'b0}};
      oc_q       <= 4'd0;
      g_q        <= {GW{1'b0}};
      step_q     <= 4'd0;
      ic_q       <= 3'd0;
      tap_q      <= 3'd0;
      ld_cnt     <= {MADDR{1'b0}};
      emit_cnt   <= 4'd0;
      rd_addr    <= {MADDR{1'b0}};
      cur_vec    <= {NP{1'b0}};
      bias_q     <= {TW{1'b0}};
      th_q       <= {TW{1'b0}};
      rom_addr_w <= {WA{1'b0}};
      out_ring   <= {T*NP{1'b0}};
    end else begin
      done      <= 1'b0;        // 默认单拍脉冲
      out_valid <= 1'b0;

      case (state)
        // ------------------------------------------------------------
        S_IDLE: begin
          if (in_valid) begin
            ld_cnt <= 1'b1;
            busy   <= 1'b1;
            state  <= S_LOAD;
          end
        end

        // ------------------------------------------------------------
        // 收满 CI*T 个 (通道,步) 向量后开始计算；中途 in_valid 有空洞也没关系
        S_LOAD: begin
          if (in_valid) begin
            if (ld_cnt == NW-1) begin
              oc_q  <= 4'd0;
              state <= S_OC_START;
            end else begin
              ld_cnt <= ld_cnt + 1'b1;
            end
          end
        end

        // ------------------------------------------------------------
        // 每个输出通道开始：装偏置/阈值，权重 ROM 指向 (ic=0,tap=0)
        S_OC_START: begin
          bias_q     <= b_rom;
          th_q       <= t_rom;
          rom_addr_w <= w_base_oc;
          g_q        <= {GW{1'b0}};
          step_q     <= 4'd0;
          ic_q       <= 3'd0;
          tap_q      <= 3'd0;
          state      <= S_GRP_START;
        end

        // ------------------------------------------------------------
        // 组间：清膜电位 + 输入读指针回到 (ic=0,t=0)（读数据下一拍可用）
        // 权重地址：本拍 ROM 还在输出 W[base]（给 tap0），到拍尾再提前到 base+1
        S_GRP_START: begin
          rd_addr    <= {MADDR{1'b0}};
          rom_addr_w <= w_base_oc + 1'b1;
          state      <= S_ACC;
        end

        // ------------------------------------------------------------
        // CI×K 拍串行累加；每步第 40 拍更新膜电位并写输出位置段
        S_ACC: begin
          // ---- 权重地址 ----
          // 80% 的拍：子步序号 +1；第 39 个子步（tap4）是步尾：
          //   还有下一步 → 提前到 base+1（下一步 tap0 的下一拍就是 tap1）
          //   是组尾     → 保持 base，留给 S_GRP_START 再读一次 base 给新组 tap0
          if (ic_q == CI-1 && tap_q == K-1)
            rom_addr_w <= (step_q == T-1) ? w_base_oc : (rom_addr_w + 1'b1);
          else if (rom_addr_w == w_last_addr)
            rom_addr_w <= w_base_oc;             // 第 38 子步 -> 回卷
          else
            rom_addr_w <= rom_addr_w + 1'b1;

          if (tap_q == 3'd0)
            cur_vec <= rd_data;                  // 锁存本输入通道的 64 位向量

          // 输入缓冲同样有 1 拍读延迟：在 tap3 就把地址切到"下一个向量"，
          // 这样 tap4 沿读进 rd_data 的正是下一个向量，tap0 直接可用。
          // 组尾（ic=7,t=15）回卷到 0，供下一组/下一通道 tap0 使用。
          if (tap_q == K-2)
            rd_addr <= (ic_q == CI-1)
                ? ((step_q == T-1) ? {MADDR{1'b0}} : {3'd0, (step_q + 4'd1)})
                : {ic_q + 3'd1, step_q};

          if (ic_q == 3'd0 && tap_q == 3'd0)
            out_ring <= {out_ring[0 +: NP], out_ring[T*NP-1 : NP]};

          if (last_sub)
            out_ring[T*NP-NP + g_q*PW +: PW] <= spike_next_v;

          // ---- 子步推进 ----
          if (tap_q == K-1) begin
            if (ic_q == CI-1) begin
              if (step_q == T-1) begin
                if (g_q != G-1) begin
                  g_q    <= g_q + 1'b1;
                  step_q <= 4'd0;
                  ic_q   <= 3'd0;
                  tap_q  <= 3'd0;
                  state  <= S_GRP_START;
                end else begin
                  emit_cnt <= 4'd0;
                  state    <= S_EMIT;
                end
              end else begin
                step_q <= step_q + 1'b1;
                ic_q   <= 3'd0;
                tap_q  <= 3'd0;
              end
            end else begin
              ic_q  <= ic_q + 1'b1;
              tap_q <= 3'd0;
            end
          end else begin
            tap_q <= tap_q + 1'b1;
          end
        end

        // ------------------------------------------------------------
        // 输出：通道优先、步次之；两组位置段已拼成完整 NP 位
        S_EMIT: begin
          out_valid <= 1'b1;
          out_ch    <= oc_q;
          out_step  <= emit_cnt;
          out_spike <= out_head;
          out_ring  <= {out_ring[0 +: NP], out_ring[T*NP-1 : NP]};

          if (emit_cnt == T-1) begin
            if (oc_q == CO-1) begin
              done  <= 1'b1;        // 与最后一个 out_valid 同拍
              busy  <= 1'b0;
              oc_q  <= 4'd0;
              state <= S_IDLE;
            end else begin
              oc_q  <= oc_q + 1'b1;
              state <= S_OC_START;
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
