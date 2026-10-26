# src/export/ —— conv 模型 int8 权重导出

把 `src/models/snn_conv.py` 的 QuantLIF/ConvSNN 权重导出为 int8 定点 ROM / 文本 / hex，
并附"定点整数模拟 vs 浮点"的逐 SNR 对拍（RTL 的黄金参照）。

**部署权重源**：`results/model_snn_distill.pt`（= 低 SNR 精调版）
（以 `results/model_snn_distill_baseline.pt` 为起点，在 SNR ∈ [−5,2] dB 子集上
CE+KD 精调 3 epoch；−5 dB 44.3% → 46.8%，0 dB 72.2% → 75.7%。
复现：`python src/train/finetune_lowsnr.py`）

## 用法

```bash
python src/export/export_int8.py                  # 导出 + 定点对拍
python src/export/export_int8.py --skip-verify    # 只导出
python src/export/export_int8.py --install        # 覆盖 hw/engine/lif 的 ROM/权重文本
```

产出在 `results/export_int8/`：

| 文件 | 内容 |
|---|---|
| `conv1_wrom.v` / `conv2_wrom.v` | RTL ROM，地址布局与 `hw/engine/lif/tb/gen_conv*_weights.py` 逐项一致 |
| `conv1_weights.txt` / `conv2_weights.txt` | 判分台金标准同款文本格式 |
| `fc1_weights.txt` / `fc2_weights.txt` | FC1（512→32，含 LIF3 阈值）/ FC2 读出层 |
| `hex/*.hex` | int8 权重、int16 偏置/阈值的二补码 |
| `manifest.json` | 每层 `s_w` / 整数范围 / 阈值 / 位宽需求 / 对拍结果 |
| `verify_int8.txt` | 定点整数模拟 vs 浮点模型的逐 SNR 识别率 |

## 定点规则（hw/engine/lif/README.md 契约 v0.1）

```
s_w    = max|W| / 127
W_int  = clamp(round(W / s_w), -128, 127)
b_int  = round(b / s_w)
th_int = max(1, round(th / s_w))        # th 取训练后的最终阈值
膜电位  LSB = s_w，16 位有符号饱和；纯 IF + 软复位
```

读出层 FC2 不经过 LIF：`argmax_c ( Σ_r W_int[c,r]·count_r + b_int[c]·T )`。

## 对拍结果（2026-10-20，精调权重）

| SNR | ckpt 浮点 | 去量化浮点 | int8 定点 | 定点−浮点 |
|---:|---:|---:|---:|---:|
| −5 | 46.84% | 46.40% | 46.72% | +0.32pp |
| 0 | 75.68% | 75.32% | 75.32% | 0.00pp |
| 5 | 90.92% | 90.92% | 90.60% | −0.32pp |
| 10 | 92.92% | 93.28% | 93.28% | 0.00pp |
| 15 | 94.52% | 94.56% | 94.68% | +0.12pp |
| 20 | 93.92% | 94.08% | 94.08% | 0.00pp |

定点路径按硬件编码（`din=round(clip(x,±4)·16)` → `n` → ΣΔ）模拟，全程 16 位饱和
**零饱和**。实测单步电流 `|x_int|` 最大：Conv1 182、Conv2 893、FC1 1755，
即 **XW=16 对三层都够用**（解析上界 9/12/13 位，不需要之前预留的 FC1 XW=18）。

真实权重已在一份临时副本上跑通 `tb_conv1_array`（1491 checks）与
`tb_conv2_array`（4280 checks）。注意 `--install` 覆盖占位 ROM/文本后，
`tb/gen_conv*_vectors.py` 里的占位权重自检锚点需要先改掉，再重新生成金标准向量。

基线对照：`results/model_snn_distill_baseline.pt`（44.3% @ −5 dB）；
精调结果另有副本 `results/model_snn_distill_lowsnr.pt`。
