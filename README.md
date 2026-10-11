# FPGA-For-Radar-Identification

基于**国产 FPGA**的**脉冲神经网络（SNN）**雷达信号智能识别系统 —— 类脑计算 × 雷达识别 × 国产化。

面向军工电池供电、长时间待机侦察场景：无信号时接近零功耗，检测到信号才唤醒完整识别引擎。

> **协作接口契约（静息域 ↔ 引擎域）：[`hw/gate/INTERFACE.md`](hw/gate/INTERFACE.md)**
> —— 两侧 RTL 开工前先读，改接口先改它。

- **软件侧**：国产类脑框架 SpikingJelly —— CNN 教师（QCFS）→ 解析式转换初始化 SNN → 三层蒸馏，权重 int8 量化导出。
- **硬件侧**：事件驱动 LIF 推理引擎 —— 脉冲编码前端 + 免乘法器 LIF 阵列 + 时间步调度 + 双域门控。

创新点与技术思路详见 [`PLAN.md`](PLAN.md)。
