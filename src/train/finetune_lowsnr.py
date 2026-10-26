# -*- coding: utf-8 -*-
"""
finetune_lowsnr.py —— 低 SNR 子集精调（LOG §8.2 的可复现版本）
================================================================
目的：把部署模型从基线（44.3% @−5 dB）换成低 SNR 精调版（表格里 46.8% 那一行）。

做法（与 §8.2 口径一致）：
    · 起点：results/model_snn_distill_baseline.pt（主训练产出的基线备份；
      第一次运行前先把 model_snn_distill.pt 复制一份过去）
    · 数据：训练集里 SNR ∈ [−5, 2] dB 的子集
    · 损失：CE + α·NLD logits 蒸馏（α=0.3，τ=2，σ=0.1）
    · 3 epoch，Adam lr=1e-3，batch=128（与主训练同超参，只做末尾局部微调）
    · 训练编码仍为 MODE='spread'（训练域 = 部署域）

产出（覆盖部署文件，基线备份保留）：
    results/model_snn_distill.pt            ← 部署用权重（= 精调结果）
    results/model_snn_distill_lowsnr.pt     ← 精调结果副本
    results/finetune_lowsnr.txt             ← 每 epoch 的逐 SNR 识别率

用法：
    python src/train/finetune_lowsnr.py
"""
import sys
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, TensorDataset

_PROJ = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_PROJ / 'src' / 'train'))
import train_distill as TD                      # noqa: E402  （顺带把 src/data、src/models 加进路径）
import snn_conv as S                            # noqa: E402

# ============================ 配置 ============================
SNR_LO, SNR_HI = -5.0, 2.0    # 低 SNR 子集（LOG §8.2）
EPOCHS = 3
LR = 1e-3                     # 与主训练一致；只微调 3 epoch
BATCH = 128
ALPHA_KD = TD.ALPHA_LOGIT     # 0.3，与主蒸馏一致
SEED = 0

CKPT_IN = TD.RESULTS / 'model_snn_distill_baseline.pt'
CKPT_OUT = TD.CKPT_DISTILL          # 部署文件（覆盖）
CKPT_COPY = TD.RESULTS / 'model_snn_distill_lowsnr.pt'
REPORT = TD.RESULTS / 'finetune_lowsnr.txt'


def eval_grid(snn, test_sets):
    """逐 SNR 评估，返回 (snrs, accs)。"""
    snrs = sorted(test_sets.keys())
    accs = []
    for s in snrs:
        a, _ = TD.eval_snn(snn, *test_sets[s])
        accs.append(a)
    return snrs, accs


def main():
    torch.manual_seed(SEED)
    np.random.seed(SEED)
    t0 = time.time()

    print('=' * 68, flush=True)
    print(f'低 SNR 精调：起点 = {CKPT_IN.name}', flush=True)
    print('=' * 68, flush=True)

    # ---------------- 数据 ----------------
    X, y, snr = TD.dataset.build_train_set(2000, cache=str(TD.CACHE))
    test_sets = TD.dataset.build_test_sets(500, cache=str(TD.CACHE))
    mask = (snr >= SNR_LO) & (snr <= SNR_HI)
    Xl, yl = X[mask], y[mask]
    print(f'子集：SNR ∈ [{SNR_LO:g}, {SNR_HI:g}] → {len(Xl)} / {len(X)} 样本，'
          f'类别分布 {np.bincount(yl).tolist()}', flush=True)
    loader = DataLoader(TensorDataset(torch.from_numpy(Xl),
                                      torch.from_numpy(yl)),
                        batch_size=BATCH, shuffle=True)

    # ---------------- 模型 ----------------
    if not CKPT_IN.exists():
        raise SystemExit(f'缺少基线备份 {CKPT_IN}；'
                         '请先把主训练产出的 model_snn_distill.pt 复制过去')
    ck = torch.load(str(CKPT_IN), map_location='cpu', weights_only=False)
    snn = S.ConvSNN(T=ck['T'], leak_shift=ck['leak_shift'],
                    hard_reset=ck['hard_reset'], use_qat=TD.QAT,
                    w_bits=TD.W_BITS, v_bits=TD.V_BITS, thr_bits=TD.THR_BITS)
    snn.load_state_dict(ck['state_dict'])

    teacher = S.ConvTeacher(act='qcfs', qcfs_L=TD.QC_LEVELS)
    tck = torch.load(str(TD.CKPT_TEACHER), map_location='cpu', weights_only=False)
    teacher.load_state_dict(tck['state_dict'])
    teacher.eval()

    snrs, base_accs = eval_grid(snn, test_sets)
    print('基线： ' + '  '.join(f'{s:+3d}dB {a * 100:5.2f}%'
                                for s, a in zip(snrs, base_accs)), flush=True)

    # ---------------- 微调（CE + KD） ----------------
    opt = torch.optim.Adam(snn.parameters(), lr=LR)
    crit = torch.nn.CrossEntropyLoss()
    rows = [('基线', base_accs)]
    for ep in range(1, EPOCHS + 1):
        snn.train()
        tot_ce = tot_kd = 0.0
        n = 0
        for xb, yb in loader:
            xT = S.encode_input(xb, TD.T, TD.MODE)
            opt.zero_grad()
            logits = snn(xT)
            ce = crit(logits, yb)
            with torch.no_grad():
                logits_t = teacher(xb)
            kd = TD.kd_nld_loss(logits, logits_t)
            loss = ce + ALPHA_KD * kd
            loss.backward()
            opt.step()
            tot_ce += float(ce) * len(xb)
            tot_kd += float(kd) * len(xb)
            n += len(xb)
        snrs, accs = eval_grid(snn, test_sets)
        rows.append((f'epoch{ep}', accs))
        print(f'  epoch {ep}/{EPOCHS}: ce={tot_ce / n:.4f} kd={tot_kd / n:.3f} | '
              + '  '.join(f'{s:+3d}dB {a * 100:5.2f}%'
                          for s, a in zip(snrs, accs)), flush=True)

    # ---------------- 保存（部署用） ----------------
    state = {'state_dict': snn.state_dict(), 'T': ck['T'],
             'mode': ck['mode'], 'leak_shift': ck['leak_shift'],
             'hard_reset': ck['hard_reset'], 'thresholds': ck.get('thresholds'),
             'snr_grid': snrs, 'accs': accs, 'baseline_accs': base_accs,
             'finetune': {'source': CKPT_IN.name, 'snr_lo': SNR_LO,
                          'snr_hi': SNR_HI, 'epochs': EPOCHS, 'lr': LR,
                          'alpha_kd': ALPHA_KD, 'seed': SEED}}
    torch.save(state, str(CKPT_OUT))
    torch.save(state, str(CKPT_COPY))

    lines = ['# 低 SNR 精调（CE+KD）逐 SNR 识别率',
             f'# 起点 {CKPT_IN.name}；子集 SNR [{SNR_LO:g}, {SNR_HI:g}]；'
             f'{EPOCHS} epoch，lr={LR}，α_kd={ALPHA_KD}',
             'SNR(dB),' + ','.join(name for name, _ in rows)]
    for i, s in enumerate(snrs):
        lines.append(f'{s},' + ','.join(f'{a[i]:.4f}' for _, a in rows))
    REPORT.write_text('\n'.join(lines), encoding='utf-8')

    print(f'\n已保存部署权重: {CKPT_OUT}', flush=True)
    print(f'精调副本: {CKPT_COPY}', flush=True)
    print(f'报告: {REPORT}', flush=True)
    print(f'总耗时 {time.time() - t0:.1f}s', flush=True)


if __name__ == '__main__':
    main()
