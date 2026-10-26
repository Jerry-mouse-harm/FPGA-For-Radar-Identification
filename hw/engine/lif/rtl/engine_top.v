// 识别引擎顶层（门控域部署形态）
//
// 干什么用的：把"编码前端 + 四级网络"串成一整帧流水，对外只暴露 §3 契约的
//             eng_start / eng_busy / eng_done / eng_class，以及样本 BRAM 的读口。
//
// 链路（全部流式直连，层间不加寄存器）：
//
//   smp_data ──► encode_frontend ──step_valid/spike_vec(128)──► conv1_array
//                     ▲                                           │ out_valid
//                     │ smp_addr                                  ▼
//                     └──────────── BRAM(128×8, 1 拍读延迟) ── conv2_array
//                                                                  │ out_valid
//                                                                  ▼
//                                                             fc1_array
//                                                                  │ spk_valid
//                                                                  ▼
//                                                               readout
//                                                                  │ done/cls
//                                                                  ▼
//                                                        eng_done / eng_class
//
// 握手（INTERFACE.md §3 + §7）：
//   · eng_start 是 clk_eng 域 1 拍脉冲（gate_ctrl 的寄存器输出，无 CDC）；
//   · eng_busy 从收到 eng_start 的下一拍起为 1，直到 readout 出结果；
//   · eng_done 在 readout done 的下一拍 1 拍，eng_class 同拍有效；
//   · 全链共用 eng_rst_n（异步低有效），复位后可连续跑多帧，无需中间复位。
//
// 为什么这样接能成立（各层的装载语义）：
//   · encode_frontend 的 16 拍 step_valid 连续无背压；conv1 的 S_LOAD 正好
//     在 in_valid 拍取样，16 拍收满即开算（中间有空洞也接受）。
//   · conv1/conv2 的输出流 per-word 带 out_valid，conv2/fc1/readout 都在
//     S_IDLE 看到第一个 in_valid 时自动进入装载，因此**不需要额外的 FSM 握手**。
//   · 每帧有效脉冲数固定（conv1→conv2 128、conv2→fc1 256、fc1→readout 16），
//     下游只数 valid，不看上游 busy/done。
//
// 端口：
//   clk_eng    : 门控域时钟（静息时停跳）
//   eng_rst_n  : 引擎复位，异步低有效
//   eng_start  : 1 拍启动脉冲
//   eng_busy   : 整帧工作期间为 1
//   eng_done   : 出结果 1 拍
//   eng_class  : 类别 0..4（与 eng_done 同拍有效，保持到下一帧）
//   smp_addr   : 样本读地址 0..N-1（由编码前端顺序扫描）
//   smp_data   : 样本读数据，**地址后 1 拍有效**（同步读 BRAM）
module engine_top #(
  parameter integer N   = 128,   // 输入样本数
  parameter integer T   = 16,    // 时间步数
  parameter integer AW  = 7,     // 样本地址位宽
  parameter integer PW1 = 16,    // Conv1 并行位置数
  parameter integer PW2 = 16,    // Conv2 并行位置数
  parameter integer LP  = 8      // FC1 并行 lane 数
)(
  input  wire              clk_eng,
  input  wire              eng_rst_n,
  input  wire              eng_start,
  output reg               eng_busy,
  output reg               eng_done,
  output reg  [2:0]        eng_class,
  output wire [AW-1:0]     smp_addr,
  input  wire signed [7:0] smp_data
);

  localparam integer NIN2 = N / 2;          // Conv1 输出位置数（OR 池化 128→64）
  localparam integer NP2  = NIN2 / 2;       // Conv2 输出位置数（OR 池化 64→32）
  localparam integer CI1  = 8;              // Conv1 通道
  localparam integer CO2  = 16;             // Conv2 通道
  localparam integer NR   = 32;             // FC1 神经元数
  localparam integer NC   = 5;              // 类别数

  localparam [0:0] S_IDLE = 1'b0;
  localparam [0:0] S_RUN  = 1'b1;

  reg        state;
  reg        fe_start;

  // ---------------- 编码前端 ----------------
  wire             fe_busy;
  wire [N-1:0]     fe_spike;
  wire             fe_step_valid;
  wire             fe_done;

  encode_frontend #(
    .N  (N),
    .T  (T),
    .AW (AW)
  ) u_fe (
    .clk        (clk_eng),
    .rst_n      (eng_rst_n),
    .start      (fe_start),
    .busy       (fe_busy),
    .smp_addr   (smp_addr),
    .smp_data   (smp_data),
    .spike_vec  (fe_spike),
    .step_valid (fe_step_valid),
    .done       (fe_done)
  );

  // ---------------- Conv1 / LIF1 ----------------
  wire          c1_busy, c1_done, c1_out_valid;
  wire [2:0]    c1_out_ch;
  wire [3:0]    c1_out_step;
  wire [N-1:0]  c1_out_spike;

  conv1_array #(
    .N  (N),
    .T  (T),
    .C  (CI1),
    .K  (5),
    .PW (PW1)
  ) u_conv1 (
    .clk       (clk_eng),
    .rst_n     (eng_rst_n),
    .in_valid  (fe_step_valid),
    .in_spike  (fe_spike),
    .busy      (c1_busy),
    .done      (c1_done),
    .out_valid (c1_out_valid),
    .out_ch    (c1_out_ch),
    .out_step  (c1_out_step),
    .out_spike (c1_out_spike)
  );

  // ---------------- Conv2 / LIF2 + OR 池化 128→64 ----------------
  wire          c2_busy, c2_done, c2_out_valid;
  wire [3:0]    c2_out_ch;
  wire [3:0]    c2_out_step;
  wire [NIN2-1:0] c2_out_spike;

  conv2_array #(
    .NIN (N),
    .NP  (NIN2),
    .T   (T),
    .CI  (CI1),
    .CO  (CO2),
    .K   (5),
    .PW  (PW2)
  ) u_conv2 (
    .clk       (clk_eng),
    .rst_n     (eng_rst_n),
    .in_valid  (c1_out_valid),
    .in_ch     (c1_out_ch),
    .in_step   (c1_out_step),
    .in_spike  (c1_out_spike),
    .busy      (c2_busy),
    .done      (c2_done),
    .out_valid (c2_out_valid),
    .out_ch    (c2_out_ch),
    .out_step  (c2_out_step),
    .out_spike (c2_out_spike)
  );

  // ---------------- FC1 / LIF3 + OR 池化 64→32 ----------------
  wire           f1_busy, f1_frame_start, f1_spk_valid, f1_frame_done;
  wire [NR-1:0]  f1_spk_vec;

  fc1_array #(
    .NPIN (NIN2),
    .NP   (NP2),
    .CI   (CO2),
    .T    (T),
    .NR   (NR),
    .LP   (LP)
  ) u_fc1 (
    .clk         (clk_eng),
    .rst_n       (eng_rst_n),
    .in_valid    (c2_out_valid),
    .in_ch       (c2_out_ch),
    .in_step     (c2_out_step),
    .in_spike    (c2_out_spike),
    .busy        (f1_busy),
    .frame_start (f1_frame_start),
    .spk_valid   (f1_spk_valid),
    .spk_vec     (f1_spk_vec),
    .frame_done  (f1_frame_done)
  );

  // ---------------- 读出层（脉冲计数 + argmax）----------------
  wire       ro_busy, ro_done;
  wire [2:0] ro_cls;

  readout #(
    .NR (NR),
    .NC (NC),
    .T  (T)
  ) u_readout (
    .clk         (clk_eng),
    .rst_n       (eng_rst_n),
    .frame_start (f1_frame_start),
    .in_valid    (f1_spk_valid),
    .in_spike    (f1_spk_vec),
    .busy        (ro_busy),
    .done        (ro_done),
    .cls         (ro_cls),
    .logits_out  ()
  );

  // ---------------- 顶层控制 ----------------
  // 只负责"启动一帧 / 等结果"；层间装载握手由各模块自己数 valid 完成。
  always @(posedge clk_eng or negedge eng_rst_n) begin
    if (!eng_rst_n) begin
      state     <= S_IDLE;
      fe_start  <= 1'b0;
      eng_busy  <= 1'b0;
      eng_done  <= 1'b0;
      eng_class <= 3'd0;
    end else begin
      fe_start <= 1'b0;          // 默认单拍脉冲
      eng_done <= 1'b0;

      case (state)
        S_IDLE: begin
          if (eng_start) begin
            fe_start <= 1'b1;    // 下一拍启动编码前端
            eng_busy <= 1'b1;
            state    <= S_RUN;
          end
        end

        S_RUN: begin
          if (ro_done) begin
            eng_done  <= 1'b1;
            eng_class <= ro_cls;
            eng_busy  <= 1'b0;
            state     <= S_IDLE;
          end
        end
      endcase
    end
  end

endmodule
