# LIF 调试日志（本地，未纳入 git）

## 2026-10-18 环境隔离 + 固定点契约 v0.1

- 本目录由 `.git/info/exclude` 仅本机排除；主仓新增提交只到 128 路编码前端 + 接缝契约。
- 训练配置确认（`src/train/train_distill.py`）：`T=16`、`LEAK_SHIFT=0`（纯 IF）、
  `HARD_RESET=False`（软复位）、`QAT=True`、`W_BITS=8`、`V_BITS=16`。
- **关键发现**：`QuantLIF` 的 `thr_bits=8` 对**标量阈值**等价于不量化——
  `fake_quant_sym` 的 scale 取 `|th|/127`，`round(th/scale)=127`，量化前后完全相同。
  所以硬件阈值位宽应按 `th/s_w` 的实际大小定（暂用 16 位），不要照搬“阈值 8 bit”的说法。
- 膜电位量化：训练端 `fake_quant_sym(v,16)` 每 forward 动态定标 `max|v|/32767`；
  硬件固定 LSB = `s_w`（与权重同尺度，保证免乘法器），16 位饱和。**固定尺度与训练动态
  定标的精度差，等真实权重导出后用整网精度对拍验证**（这是后续必须做的一步）。
- 偏置训练端不量化，硬件折成 `b_int = round(b/s_w)`。
- 首个模块 `rtl/lif_neuron.v`：整数域 IF + 软复位 + 16 位饱和；判分台用整数模型金标准。

## 2026-10-18 单神经元完成（判分台 PASS + 变异全抓）

- `rtl/lif_neuron.v`：每拍 `v = sat16(v + x)` → `s = (v >= th)` → `v = s ? v-th : v`；
  `step_valid=0` 时 v/spike 冻结。参数 `VW=16, XW=16, TW=16`（层阵列可改 XW）。
  **时序**：寄存器输出，step_valid 上升沿更新；层间天然 1 拍流水延迟，接缝不要再加寄存器。
- `tb/gen_lif_vectors.py`：纯整数金标准，24 用例 × 16 步，生成 `th/x/spike_exp/v_exp.hex`。
  覆盖阈值边界、慢积分、多发、正负混合、双向饱和、阈值上限撞线/差一点、阈值 1、无泄漏、4 随机。
- `tb/tb_lif_neuron.v`：`make lif` → **PASS（392 checks）**；另有 3 项结构检查：
  异步复位立即生效 / step_valid=0 完全冻结 / 复位后首拍为 0。
- **变异测试 7/7 全抓**（临时改 /tmp 的副本，不动仓库）：
  `>=`→`>`（68）、去饱和（56）、去 step_valid 门控（5）、硬复位（189）、
  同步复位（1，只有异步复位检查抓）、加法器不扩位（56）、软复位减两次（186）。
- **踩坑修正**：一开始把 `x=99, th=100` 当"攒不满"锚点，错了——纯 IF 会累积，
  t=1 就发。正确锚点是 `x=6`（16×6=96<100）与 `x=10`（t=9 恰好 100）。
- 综合（GW2AR-18，`synth_gowin`）：单神经元 ≈60 LUT + 17 DFFCE（16 膜电位 + 1 spike）。
  DFFCE 带时钟使能，正好对应 step_valid 门控。
- **层阵列位宽预警（下一步要用）**：FC1 扇入 512，单步加权和最大 `512×127=65024`、
  最小 `512×(-128)=-65536` → **XW 至少 17 位**（-65536 恰好是 17 位有符号下限），
  再留偏置余量取 **XW=18** 稳妥。`lif_neuron` 的加法器已写成 `AW=max(VW,XW)+1`，例化时改参数即可。
  （训练端膜电位是每 forward 动态定标，硬件固定 LSB=s_w，FC 层是否饱和失真待真实权重对拍。）

## 2026-10-18 Conv1 阵列 + 权重 ROM（PASS + 12 变异 + 资源实测）

- **数据通路**：`rtl/conv1_array.v`（Conv1 8 通道 × 128 位置 × k5 × pad2 × T16）。
  三段串行：通道串行（一次一个输出通道的全部 16 步）× 位置分组串行（PW=32，G=N/PW=4）× 抽头串行（5 拍/步）。
  位置组之间互不依赖 → **只保留一组 32 个膜电位**，每组开始清 0；第 5 拍同时完成
  `x_final` 条件加、饱和、判发、软复位、写输出段。
- **权重 ROM**：`rtl/conv1_wrom.v` 由 `tb/gen_conv1_weights.py` 自动生成（组合 case，三端口：
  `addr_w=ch*5+tap`、`addr_b=40+ch`、`addr_t=48+ch`）。当前是**固定种子合成占位权重**
  （故意含 127/-128 极值）；真实导出换数值源即可，格式不变。
- **金标准**：`tb/gen_conv1_vectors.py` 纯整数模型（同一份 `conv1_weights.txt`），10 帧
  （全 0/全 1/单点走边界与组交界/交替/前静默后爆发/稀疏/密集/随机），逐位对拍。
- **判分台** `tb/tb_conv1_array.v`：`make conv1` → **PASS（1491 checks）**。除逐位对拍外查：
  装载期不得输出、第一个 `in_valid` 后 `busy` 拉高、输出标签必须 ch 优先/step 次之、
  每个 (ch,step) 恰好一次、`done` 只在最后通道最后一拍、`done` 后接口全落、连续 10 帧不复位。
- **变异 12/12 全抓**（临时改副本，脚本 `logs/mut_conv1.py`）：
  `>=`→`>`、硬复位、不清膜电位、pad 切片偏 2、跳组、组段写反、每抽头加偏置、
  权重反向、去软复位、输出环反转、预取错字、装载槽错位。
- **周期**：16 装载 + 8 通道 × (4 组 × (16×5+1) + 16 输出) = **2736 拍 ≈ 101 µs @27MHz**
  （判分台仿真在 100MHz 下 27.4 µs/帧）。
- **资源（重要，决定 PW）**：先用 PW=64 两组：yosys 后 nextpnr **LUT4 88%，布局失败**。
  改成 PW=32 四组后：**LUT4 51%、DFF 36%、ALU 18%、最高时钟 56 MHz（27MHz 时序 PASS）**。
  代价是周期翻倍（53→101 µs）。PW=64 撑爆的原因是 64 条 lane 的加法器/比较器 + 广播
  权重/阈值的扇出，不是帧缓存 mux。
- **环形帧缓存**：`spk_ring`/`out_ring` 各 16×128 bit，每步整体旋转一个字（纯连线，0 LUT），
  避免 16:1 读写 mux。两条对齐铁律：①每通道旋转总数必须是 16 的倍数
  （16 步×G 组 + 16 输出 = 16(G+1)）；②tap4 预取下一步必须读 `spk_ring[N +: N]`
  （NBA 还没旋转，头部的下一个字才是旋转后的新头部）。
- **踩坑**：`done` 最初每个通道输出完都拉高 → 每帧只出 16 个结果，后续帧撞上 busy。
  修正为仅 `ch_q==C-1` 的最后一拍 `done`，其余通道无缝回 `S_CH_START`。
- **待办（2026-10-20 已完成）**：真实 checkpoint → int8 导出与整网固定尺度精度对拍，
  见本文件末尾“int8 导出（精调部署权重）”一节。

## 2026-10-20 Conv2 阵列 + 权重 ROM（PASS + 15 变异 + 资源实测）

- **数据通路**：`rtl/conv2_array.v`（Conv2 16 通道 × 64 位置 × 8 输入通道 × k5 × pad2 × T16）。
  装载期对 128 位输入做 **OR 池化**（相邻两位相或）存进 8×16×64 缓存；
  计算期 输出通道串行 × 位置分组串行（PW=32，G=2）× 输入通道/抽头串行（40 子步/步）。
  只保留一组 32 个膜电位；输入帧缓存用同步读 RAM（防 128:1 mux 吃 LUT）。
- **权重 ROM**：`rtl/conv2_wrom.v` 由 `tb/gen_conv2_weights.py` 生成，640 项同步读 + 1 拍流水，
  地址提前一拍预取；当前仍是固定种子合成占位权重，真实导出后只换数值。
- **金标准**：`tb/gen_conv2_vectors.py` 纯整数模型，11 帧覆盖池化边界/奇偶位/成对位/静默后爆发/稀疏/密集/随机。
- **判分台** `tb/tb_conv2_array.v`：`make conv2` → **PASS（4280 checks，11 帧×16ch×16step×64pos）**。
- **变异 15/15 全抓**（`logs/mut_conv2.py`）：LIF 规则 4 项、池化/窗口 4 项、累加 1 项、
  权重 ROM 时序 2 项、输入缓冲时序 2 项、输出顺序/旋转 2 项。
- **周期**：128 装载 + 16 × 1299 = **20912 拍/帧 ≈ 774 µs @27MHz**
  （输入通道 8×、输出通道 2×、抽头 5× 都串行；后续可做输入/输出通道并行压缩）。
- **资源（单独综合 GW2AR-18）**：LUT4 6205/20736 = 30%、DFF 2583、BSRAM 3、ALU 3142；
  最高时钟 **61.04 MHz（27MHz 时序 PASS）**。
- **Conv1+Conv2 级联资源**：LUT4 **18938/20736 = 91%**、DFF 51%、ALU 38%、BSRAM 6%。
  这个占用很紧，布局能否收敛待确认；下一版可能需要把两层的 lane 算术做成时分复用，
  或降低 PW / 改成通道并行度更小的架构来腾资源。

## 2026-10-20 PW=32 → 16：级联资源收敛验证（PASS）

- **动机**：PW=32 时 Conv1+Conv2 级联 LUT4 91%，nextpnr 全局布局 50 分钟以上不收敛
  （两次独立尝试都卡在 placement，无布线结果）。
- **改动**：`conv1_array` / `conv2_array` 默认 `PW=16`（Conv1 G=8，Conv2 G=4），
  判分台参数与超时同步调整；RTL 数据通路未改。
- **数值判定**：`make conv1` / `make conv2` 仍 **PASS，check 数与 PW=32 完全一致**
  （1491 / 4280）→ **逐位等价，精度零变化**，不需要重训。
- **周期**：Conv1 5328 拍/帧（197 µs），Conv2 41424 拍/帧（1534 µs），
  级联约 1.73 ms/帧 @27MHz（PW=32 时约 0.88 ms）。
- **资源（GW2AR-18，nextpnr 布线后实测）**：
  · Conv2 单独：LUT4 **4432/20736 = 21%**、DFF 13%、ALU 10%、BSRAM 3、
    Fmax **56.92 MHz（27MHz PASS）**。
  · Conv1+Conv2 级联：LUT4 **8696/20736 = 41%**、DFF 44%、ALU 19%、BSRAM 3、
    Fmax **57.35 MHz（27MHz PASS）**，布局布线正常完成。
- **结论**：时间换空间有效，PW=16 定为默认。若后续要追周期，可做两层共享 lane
  或把引擎时钟提到 54 MHz（需重开契约 C5）。

## 2026-10-20 int8 导出（精调部署权重）+ 定点对拍

- **导出脚本**：`src/export/export_int8.py`（输入 `results/model_snn_distill.pt`，
  即低 SNR 精调版）。按契约 v0.1 逐层量化：`s_w=max|W|/127`、
  `W_int=clamp(round(W/s_w),-128,127)`、`b_int=round(b/s_w)`、
  `th_int=max(1,round(th/s_w))`（**th 用训练后的最终阈值**，不是 checkpoint 里
  `thresholds` 记录的那组转换初值）。
- **实测量化参数**：
  · Conv1 `s_w=0.00615323`，W_int∈[−112,127]，b_int∈[−74,82]，**th_int=68**
  · Conv2 `s_w=0.00290257`，W_int∈[−121,127]，b_int∈[−21,41]，**th_int=154**
  · FC1   `s_w=0.00466423`，W_int∈[−124,127]，b_int∈[−7,13]， **th_int=271**
  · FC2（读出）`s_w=0.00649664`，W_int∈[−127,125]，b_int∈[−20,16]，无 LIF
- **产出**（`results/export_int8/`）：`conv1_wrom.v` / `conv2_wrom.v`（地址布局与
  `tb/gen_conv*_weights.py` 完全一致）、`conv{1,2}_weights.txt`、`fc{1,2}_weights.txt`、
  `hex/*.hex`（int8 权重 / int16 偏置与阈值）、`manifest.json`、`verify_int8.txt`。
- **定点对拍**（硬件编码 `din=round(clip(x,±4)*16)` + ΣΔ + 16 位饱和 + 软复位；
  输入样本与 checkpoint 同一测试集）：精调浮点 46.84/75.68/90.92/92.92/94.52/93.92%
  → int8 定点 **46.72/75.32/90.60/93.28/94.68/94.08%**（−5/0/5/10/15/20dB），
  与"去量化浮点参考"逐档差 ≤0.32pp，**三层零饱和**。
- **位宽结论（更新之前的 FC1 预警）**：真实权重下观测 `|x_int|` 最大
  Conv1 182 / Conv2 893 / FC1 1755；解析上界（对应通道全 1 输入）
  Conv1 168~−182（9 位）/ Conv2 1130~−636（12 位）/ FC1 3655~−3142（13 位）。
  → **XW=16 对 Conv1/Conv2/FC1 都足够**，之前按"权重全 ±127"估的 FC1 XW=18 是
  最坏上界，真实网络用不到。膜电位 16 位饱和在实测中从未触发。
- **真实权重上判分台**：在 `/tmp` 临时副本里用导出的 ROM + 按真实权重重新生成的
  金标准向量，`tb_conv1_array` **PASS（1491 checks）**、`tb_conv2_array`
  **PASS（4280 checks）**；iverilog 编译两个 ROM 也通过。仓库内仍保留占位权重，
  因为 `tb/gen_conv*_vectors.py` 里有占位权重的自检锚点（如"c0 全不发"），
  换真实权重前要先删/改这些锚点。
- **读出层约定**：FC2 不经过 LIF，硬件按 T 步脉冲计数读出
  `argmax_c ( Σ_r W_int[c,r]·count_r + b_int[c]·T )`（除以 T 只是全局缩放）。
- **下一步**：FC1/FC2 RTL（`lif_neuron` 阵列 + 5 位计数器 + argmax readout），
  以及把真实 ROM 正式装进 `hw/engine/lif`（`export_int8.py --install`）。

## 2026-10-21 FC1/LIF3 + 读出层（PASS + 29 变异 + 四级链路布局收敛）

- **第二次 OR 池化 + FC1**：`rtl/fc1_array.v` 装载期对 Conv2 的 64 位输出做 64→32
  OR 池化，按 `{通道, 步}` 存入 256×32 bit 同步读缓存；计算期每步 512 个输入串行扫，
  神经元按 **LP 条 lane × NG=NR/LP 趟** 分时（当前默认 **LP=8**，每步 4 趟）。
  `c = o*32 + j` 的 flatten 顺序与训练端一致。
- **权重 ROM**：`rtl/fc1_wrom.v` 512 地址 × 32 神经元 × int8 = 8 个 BSRAM bank，
  同步读 + 1 拍流水；偏置/阈值是每神经元常量，32×16 bit 直接由 ROM 端口给。
  这样 lane 里没有偏置/阈值 ROM 地址译码，只有 2:1/4:1 常量切片选择。
- **LIF3 时序**：每趟 1 拍 `S_STEP_START` + 512 拍 `S_ACC` + 1 拍 `S_LIF`。
  第 512 拍把最后一项也累进 acc，`S_LIF` 拍只做"饱和 + 比较 + 软复位"三个加法器
  （早期版本为最后一项单独留一个 acc 加法器，已删）。
  **末趟才发 `spk_valid`**，32 位脉冲一次给全，下游 readout 每步只收一拍。
- **读出层**：`rtl/readout.v` + `rtl/readout_wrom.v`，纯脉冲计数
  `argmax_c (Σ_r W_int[c,r]·count_r + b_int[c]·T)`；偏置按 `<<< log2(T)` 实现，
  无乘法器；argmax 用 `>` 保证**低索引优先**（与 PyTorch `argmax` 一致）。
- **调试踩的 5 个坑**（都已修，探针脚本 `logs/probe_rom.v` / `logs/probe_fc1.v`）：
  1. lane 里 `acc[l]` / `v[l]` 误写成对 16 位向量的位选 → 高 lane 全 X；
  2. 移位寄存器切片写成 `[NP-2:0]`（左拼接其实不右移）→ 整个字只读 bit0；
  3. 步首才设 `rd_addr` 晚一拍 → 第一步读到上一步的尾巴，改为步尾预取；
  4. 权重 ROM 同步读需地址提前一拍，`S_STEP_START` 预置 addr=1、addr=0 在上一拍；
  5. 通道切换预取要在 `c[LB-1:0]==NP-2`（本字倒数第二拍），不是最后一拍。
- **判分台**：`make fc1` → **PASS（3048 checks，11 帧×16 步×32 神经元）**；
  `make readout` → **PASS（5908 checks）**。tb 的看门狗按 `NG` 参数化。
- **变异 29/29 全抓**（`logs/mut_fc.py`）：LIF 规则 4、池化/位提取 3、输入缓存 4
  （含新增"趟结束不回卷读地址"）、权重 ROM 2、累加 3、输出/分组 4、
  读出层 9（argmax tie、偏置、移位方向、帧清零、busy/done 时序等）。
- **周期（LP=8）**：每步 4×(514)+1 ≈ 2057 拍，单帧 256 + 16×2057 ≈ **33.2k 拍
  ≈ 1.22 ms @27MHz**；readout 约 530 拍。四级链路整帧 ≈ **2.97 ms**。
  LP=16 时 FC1 ≈ 618 µs，但布局不通（见下）。
- **资源与布局（GW2AR-18，nextpnr 实测）**：
  · **LP=16**：LUT4 13185 (63%)、ALU 4504 (28%)、DFF 8252 (53%)，
    宽 mux 折算（MUX2_LUT5×2/6×4/7×8/8×16）再占 ~11k LUT4 站点 → 等效 **117%**，
    两种 placer/两个 seed 都报 `Unable to find legal placement`。**根因不是单项百分比，
    而是 LUT4 站点 + 宽 mux 站点之和超 20736。**
  · **LP=8**：LUT4 **10681 (51%)**、MUX2_LUT5 13%/LUT6 4%/LUT7 1%/LUT8 0%、
    ALU **3938 (25%)**、DFF 8128 (52%)、BSRAM 12 (26%)；**布局布线通过**，
    Fmax **47.7 MHz（时序驱动布局）/ 60 MHz（布后，seed1）**，27MHz PASS。
  · 残留 **288 条 hold 违规（最差 −0.12 ns）**，全在 FC1 权重 ROM 的 BSRAM 地址脚
    （`w_addr` 寄存器离 BSRAM 太近，clk-to-q+routing=0.75ns vs 0.63ns+不确定度）。
    两个 seed 都是同一批路径；属边际问题，上板验证时重点看，必要时在地址脚串 LUT 延迟。
- **LP 取舍**：LP 只是并行度参数，不改任何算术（判分台 check 数与 LP=32/16/8 完全一致）。
  默认定 **LP=8**：四级链路可布局、整帧 2.97 ms，仍远快于"人眼/雷达帧"尺度。
  若后续要压时延，优先试 `XW` 16→13/14 或 Conv2 通道并行，再考虑 LP 回调。

## 2026-10-23 引擎顶层集成（进行中，停在判分台之前）

- **已写 `rtl/engine_top.v`（尚未仿真）**：encode_frontend → conv1 → conv2 → fc1 → readout
  **流式直连**。依据各层装载语义：下游都在 `S_IDLE` 看到第一个 `in_valid` 自动进入装载，
  自己数 valid（conv1↔frontend 16、conv1→conv2 128、conv2→fc1 256、fc1→readout 16），
  因此层间**不需要额外握手 FSM**。顶层 FSM 只做两件事：收 `eng_start` → 发 1 拍 `fe_start`；
  等 `readout.done` → 下一拍给 `eng_done/eng_class`、`eng_busy` 落。
  对外端口 = INTERFACE §3 的 4 个信号 + `smp_addr/smp_data`（BRAM 同步读 1 拍）。
- **已写并跑通 `tb/gen_engine_vectors.py`**：从 din 样本走
  `sample_to_n + ΣΔ + Conv1/Conv2/FC1/readout` 整数模型，产出
  `tb/engine_smp.hex`（9 帧×128 样本）、`tb/engine_cls_exp.hex`、`tb/engine_logits_exp.hex`。
  自检锚点：n 的 5 个规格点、全零帧 0101、三层零饱和、类别覆盖 ≥2。
  **占位权重下 9 帧类别只覆盖 {2,3}**（真实权重装上后应更分散）。
- **还没做**：`tb/tb_engine_top.v`（BRAM 1 拍延迟模型、逐帧 eng_start、busy/done 协议检查、
  class/logits 对拍、看门狗 ~150k 拍/帧）、Makefile `engine` 目标、顶层互连变异、
  真实权重安装（FC1/readout ROM + 合并 txt + 占位锚点改造）。
- 写 tb 时的两个现成约定：采样用 `@(negedge clk)` 或 `@(posedge clk); #1;` 避开 NBA 竞争；
  logits 可用层次引用 `u_ro.logits_out`（顶层没把它引出端口）。
- 板子今天重新 attach 成功：WSL 内 `usbipd.exe attach --wsl --busid 3-2` →
  `openFPGALoader --detect` 认到 `GW2A(R)-18(C)`；仍**未烧录**。

## 2026-10-24 引擎顶层判分台 + 真实权重安装（已完成）

- **`tb/tb_engine_top.v` 完成**：9 帧 din 样本端到端（encode_frontend → Conv1 →
  Conv2 → FC1 → readout），样本 BRAM 按"地址后 1 拍"建模；逐帧检查
  class + logits、busy 不可中途掉、done 单拍、done 后 class 保持、连续多帧不复位；
  第 4 帧中途插一个假 `eng_start`，顶层 FSM 必须忽略。
  **PASS（73 checks）**，单帧恒定 **79687 拍 ≈ 2.95 ms @27MHz**。
  入口：`make engine`（依赖 `$(ENGV)`，权重变了会自动重算向量）。
- **顶层互连变异 `logs/mut_engine.py`：13/13 全抓**（编码→Conv1 valid/位序、
  Conv1→Conv2 valid/ch-step/位序、Conv2→FC1 ch-step/valid、FC1→readout valid/脉冲、
  busy/done/class 握手）。结果留档 `logs/mut_engine.txt`。
- **真实权重安装 `tb/install_real_weights.py`**：
  · conv1/conv2 的 ROM 与权重文本直接复制 `results/export_int8/`；
  · 导出的 FC1（`W r c / B r / T r`）+ FC2（`W c r / B c`）合并为测试台原有的
    `W1/B1/T1/W2/B2` 文本，并按既有布局生成 `rtl/fc1_wrom.v` / `rtl/readout_wrom.v`。
  · 真实值：Conv1 th=68、Conv2 th=154、FC1 th=271；FC1 b∈[-7,13]；
    FC2 B2=[-2,16,-20,-11,14]；logits 保守上界 326720 < 2^19。
  · 占位锚点改造：三个 `gen_*_vectors.py` 里与占位权重数值绑定的 assert
    （全负通道永不发、zero 帧 class=3 等）改为与权重无关的检查
    （位宽、全 1≠全 0、池化等价、类别覆盖 ≥2）。
- **真实权重回归全绿**：conv1 1491 / conv2 4280 / fc1 3048 / readout 5908 checks PASS；
  顶层 9 帧 PASS。9 帧类别覆盖 **{0,3,4}**。
- **整颗引擎资源评估（进行中）**：`logs/engine_fit_top.v` = engine_top + 128×8
  同步样本 BRAM + 自动起帧，`synth_gowin -family gw2a`：
  LUT1/2/3/4 = 573/2018/7054/2937，MUX2_LUT5/6/7/8 = 2642/908/360/157，
  ALU 5299，DFF≈9230，BSRAM 12。**真实权重比占位权重的组合逻辑明显多**
  （占位四层链 LUT1-4 合计 7759 → 现在 12582），nextpnr 布局结果待补。

## 2026-10-24 整颗引擎 PnR 收敛：降并行 + `-noalu`（已完成）

- **并行度参数化**：`conv1_array` / `conv2_array` 的位置组计数器原为固定位宽
  （conv1 `reg [2:0] g_q`、conv2 `reg [1:0] g_q`），PW 降到 8 时组数变成 16/8，
  计数器回绕 → `g_q != G-1` 永不成立 → 死锁。改为
  `localparam GW = (G > 2) ? $clog2(G) : 1;` + `reg [GW-1:0] g_q`。
  **默认 PW=16 行为不变**：conv1 1491 / conv2 4280 / 顶层 73 checks 全 PASS，
  logits 与改前逐位一致，仍 79687 拍/帧。
- **低并行配置 PW1=8 / PW2=8 / LP=4**（`make engine_lowp`）：
  **PASS 73 checks，9 帧 logits 与默认配置逐位相同**，158791 拍/帧 ≈ **5.88 ms @27MHz**。
  并行度只影响周期数，不影响任何算术结果（再次验证）。
- **资源（synth_gowin）**：
  · LUT1/2/3/4 = 534/1410/4818/2416（合计 9178，默认 LP=8 时 12582）
  · ALU 3673、DFF ≈8656、BSRAM 12
- **PnR 卡点与根因**：
  · 全并行（LP=8 + PW=16）LUT4 91% + 宽 mux 超站点，heap placer 永远合法化不了。
  · PW=8 后容量只有 ~56%，但 heap 分析布局器仍在 **iteration #7 的
    `legalise_placement_strict` 卡死**（#1–6 各 10–20 s，#7 20 分钟无输出）；
    `--placer sa` 在该设计上初始布局直接**段错误**（1/8 线程均复现）。
    调 `--no-tmdriv` / `alpha` / `beta` / `cell-placement-timeout` 都绕不过。
  · `--debug-placer` 暴露卡点：合法化在逐条处理**长 DFFCE/ALU 进位链**
    （`ALU_COUT_CIN` 命名的链）——Gowin 进位链邻接约束让合法化搜索爆炸。
- **解法：`synth_gowin -noalu`**（加法器退化为纯 LUT，不生成 ALU 进位链）：
  · 综合：LUT1-4 = 11803（+29%），ALU **0**，宽 mux 3219/902/348/116，
    DFF 8656，BSRAM 12。
  · nextpnr **一次通过**：LUT4 **11803/20736 (56%)**、MUX2_LUT5 31%/LUT6 17%/
    LUT7 13%/LUT8 4%、DFF 55%、BSRAM 26%、ALU 0。
  · **Fmax 51.77 MHz（27 MHz PASS）**；11 条 hold 违规，最差 **−0.12 ns**，
    全部在 FC1 权重 ROM 的 BSRAM 地址脚（与之前 LP=8 的 288 条同源，属边际问题）。
  · bitstream 已生成：`logs/engine_fit_lowp.fs`（7.26 MB）。
- **结论**：整颗真实权重引擎在 GW2AR-18 上可放下（56% LUT4 / 55% DFF / 12 BSRAM），
  27MHz 时序成立；代价是帧时延 5.88 ms 与 `-noalu` 的综合选项。
  上板时优先用 `-noalu` 网表；若上板发现 hold 边际问题，在 FC1 ROM 地址脚串 LUT 延迟。
- **待办**：`-noalu` 只改加法器实现，RTL 仿真结果不变；上板前建议对 `-noalu`
  JSON 做一次 gate-level 快速回归（或直接上板看 LED）。板子当前未枚举（USB 掉线）。
