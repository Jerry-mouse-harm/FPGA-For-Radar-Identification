# Verilog 手撕实验室（verilog_lab）

> 目标：不看资料，手撕竞赛最经典的 5 个模块 + 项目本体的脉冲编码前端，且每个都能用 testbench 仿真验证通过。
> 配套：PLAN.md（SNN 雷达识别项目）、VERILOG_LEARNING.md（15天基础）。

## 训练法（每个模块固定流程）

1. 看规格 + 记忆套路（先别急着看别人代码）
2. 自己在对应目录里从零手写 RTL（只允许参考我给的骨架/思路）
3. `make <模块>` 跑 testbench 仿真，看波形/打印自测
4. 全过 → 我来逐行复盘你的代码，指出坑
5. 过几小时/第二天默写一遍（对抗遗忘，这是"手撕"的真谛）

## 模块清单（含项目对应关系）

| 目录 | 模块 | 自撕文件 | 对应 SNN 项目技能 |
|------|------|----------|-------------------|
| m1_counter_div | 计数器 + 任意分频(偶/奇 50%) | counter.v, div_N.v | 时间步调度器 / 时序基础 |
| m2_debounce | 边沿检测 + 按键消抖 | edge_det.v, key_debounce.v | 输入处理 |
| m3_shift | 移位寄存器 + 并串/串并转换 | shift_reg.v, p2s.v, s2p.v | 数据通路 / 延迟线 |
| m4_fsm_seq | 三段式状态机（序列检测 1011） | seq_det.v | 控制 FSM（项目灵魂） |
| m5_uart | UART 收发（8N1, 波特率可配） | uart_tx.v, uart_rx.v | 上位机通信 |
| m6_encoder | 脉冲编码前端（定点映射 + ΣΔ spread） | sample_to_n.v, spike_encoder.v | **项目本体**：BRAM → 脉冲序列 |

> m6 是项目自己的模块，`gen_vectors.py` 调用 `src/models/snn_conv.py::encode_input` 生成金标准
> （编码域必须与训练端一致 —— LOG.md 的铁律）。改了编码参数就重跑一次生成 hex。

## 仿真命令

```
make m1        # 编译并跑 M1 全部 testbench
make m1_view   # 跑完用 GTKWave 打开波形
make clean
```
（Makefile 由助手环境就绪后生成，指向 conda env 里的 iverilog）
