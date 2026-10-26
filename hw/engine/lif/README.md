# LIF 本地调试区（环境隔离）

> 本目录被 `.git/info/exclude` **仅本机**排除：LIF 代码/日志不会出现在主仓 git 状态里。
> **用户说“git”时才纳入主仓**。在此之前不要动已提交的公共文件（`hw/engine/encode_frontend.v`、
> `hw/gate/INTERFACE.md` 等）；确需改契约，先在主仓改契约文件并同步。

## 目录

| 路径 | 用途 |
|---|---|
| `rtl/` | LIF 相关 RTL |
| `tb/` | testbench + 金标准生成器 + hex 向量 |
| `logs/` | 仿真输出 / 波形（本地，永不提交） |
| `LIF_LOG.md` | 设计决策与调试结论（本地日志） |

## 固定点契约 v0.1（2026-10-18）

训练侧事实（`src/train/train_distill.py`）：
- `T = 16`，`LEAK_SHIFT = 0` → **纯 IF，无泄漏减法器**，`HARD_RESET = False` → 软复位
- QAT：`W_BITS = 8`，`V_BITS = 16`；权重按 `fake_quant_sym` 的对称量化

硬件映射（每层独立）：

| 量 | 规则 |
|---|---|
| 权重 | `s_w = max|W| / 127`，`W_int = round(W / s_w) ∈ [-128, 127]` |
| 偏置 | `b_int = round(b / s_w)` |
| 阈值 | `th_int = round(th / s_w)`（**不照搬训练端的 8 bit**，见 LIF_LOG） |
| 膜电位 | LSB = `s_w`，16 位有符号，**饱和**到 `[-32768, 32767]` |

每个时间步（整数域，无乘法器）：

```
x_int = Σ（发放脉冲对应的 W_int） + b_int      // 0/1 脉冲 → 条件加
v     = sat16(v + x_int)
s     = (v >= th_int)
v     = s ? v - th_int : v                      // 软复位
```

## 模块路线

1. `rtl/lif_neuron.v` —— 单神经元（已完成：判分台 PASS + 7 项变异全抓）
2. `rtl/conv1_array.v` + `rtl/conv1_wrom.v` —— Conv1 阵列（已完成：PASS + 12 项变异全抓；
   PW=16 八组，LUT4 41%（级联））
3. `rtl/conv2_array.v` + `rtl/conv2_wrom.v` —— Conv2 阵列 + OR 池化 128→64
   （已完成：PASS + 15 项变异全抓）
4. `rtl/fc1_array.v` + `rtl/fc1_wrom.v` —— 第二次 OR 池化 64→32 + FC1/LIF3
   （已完成：PASS + 变异全抓；默认 **LP=8**，每步扫 4 趟，单帧 ≈33k 拍 ≈1.22ms）
5. `rtl/readout.v` + `rtl/readout_wrom.v` —— FC2 脉冲率读出 + argmax
   （已完成：PASS + 变异全抓）
   两层合计 `logs/mut_fc.py` **29/29 全抓**；四级链路（Conv1→Conv2→FC1→Readout）
   `logs/fc_fit_top.v` 在 GW2AR-18 上布局布线通过（LUT4 51%、ALU 25%、DFF 52%），
   整帧 ≈2.97ms @27MHz
6. 与 `encode_frontend` 的 `spike_vec/step_valid` 接缝联调 + 引擎顶层集成（下一步）

## 命令

```bash
make -C hw/engine/lif vectors    # 重新生成神经元 tb/ 金标准
make -C hw/engine/lif lif        # 跑神经元判分台
make -C hw/engine/lif weights    # 重新生成 Conv1 占位权重 + rom
make -C hw/engine/lif conv1      # 跑 Conv1 阵列判分台
make -C hw/engine/lif conv2      # 跑 Conv2 阵列判分台
make -C hw/engine/lif fc_weights # 重新生成 FC1/读出层占位权重 + rom
make -C hw/engine/lif fc1        # 跑 FC1/LIF3 阵列判分台
make -C hw/engine/lif readout    # 跑读出层（argmax）判分台
make -C hw/engine/lif view_conv1 # 看波形（同理 view_conv2 / view_fc / view_readout）
```
