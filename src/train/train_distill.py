# -*- coding: utf-8 -*-
"""
src/train/train_distill.py —— CNN 教师 → QCFS 转换初始化 → 三层蒸馏 SNN
=======================================================================
流程（每阶段都按 SNR 出识别率，主指标 ACC）：
    ① 教师    : QCFS 量化激活的 CNN，软标签/特征/显著性的来源（上限）
    ② SNN 直训: 随机初始化 + 代理梯度 BPTT + CE（对照基线）
    ③ 转换初始化: 拷贝教师权重 + 解析式 λ/8 定阈值 + 折算权重（不训练，看零样本迁移）
    ④ 三项蒸馏微调: ③ 的起点 + NLD logits + 膜电位 + 显著性（本方案核心）

★ 训练编码 = 部署编码 = MODE（默认 'spread' ΣΔ 均匀率编码）。
  这是踩过坑之后定下来的：用 direct（模拟电流）训练、部署时换打脉冲输入，
  实测掉 24pp——编码域不一致的代价远大于任何蒸馏收益。脉冲域直训后，
  部署口径的 ACC 就是训练时看到的 ACC，不存在"验证时掉点"的问题。

★ 蒸馏权重必须轻（0.3 / 0.02 / 0.1）。取 1.0/1.0/1.0 时蒸馏项占总损失 77%，
  结果蒸馏(70%@20dB) 反而**不如纯 CE 直训**(85%)——正则项压垮了主目标。

三层蒸馏（对应 snn_conv.ConvSNN 的缓存）：
    logits : NLD 噪声平滑蒸馏 —— SNN logits 稀疏尖峰，先加高斯噪声平滑再对教师
             连续分布做温度 KL（否则逐元素对齐是次优的，见 arXiv 2511.06902）
    膜电位 : 教师末层激活 a3 (B,32) ↔ 学生 LIF3 膜电位时间平均 v3 (B,32)
             各按 batch 内 std 归一化消除量纲差（MD-SNN, DATE'26 的思路）
    显著性 : 类感知线性化 CAM —— g_c = W2[c] @ W1 reshape 成 (16,64)，
             给 conv2 特征图的每个空间位置加权，softmax 成"关注哪里"的分布
             （教师用 conv2 激活图，学生用同位置的 spike 发放率图）后 KL

QAT：权重 int8 / 膜电位 int16 / 阈值 int8 的 fake-quant 全程开启（可直接关闭对比）。
     位宽先取宽松值——"先提 ACC"，跑通后再逐项收紧。

用法：
    python src/train/train_distill.py
产出：
    results/model_teacher_qcfs.pt, results/model_snn_distill.pt
    results/distill_compare.png, results/distill_compare.txt
"""
import os
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, TensorDataset

torch.set_num_threads(8)

_PROJ = Path(__file__).resolve().parent.parent.parent
# 扁平 import（见 LOG.md 第 1 节）：把 src/data、src/models 加进搜索路径
for _d in ('data', 'models'):
    sys.path.insert(0, str(_PROJ / 'src' / _d))
import dataset                                     # noqa: E402
import snn_conv as S                               # noqa: E402

# ============================ 配置 ============================
T = 16                    # 时间步（QCFS 的 L 取同值，转换误差 O(1/T)）
LEAK_SHIFT = 0            # 0 = 纯 IF，与 QCFS 精确对应且硬件最简（无减法器）
HARD_RESET = False        # 软复位（减法器，保留余量）
QAT = True                # 是否开启定点 fake-quant
W_BITS, V_BITS, THR_BITS = 8, 16, 8
QC_LEVELS = 16            # 教师的 QCFS 量化级数

# 训练编码 = 部署编码。SNN 的精度对编码方式很敏感：若用 direct 训练再换打
# 脉冲输入，实测掉 24pp（编码/训练的域不一致）。所以直接在脉冲域训练，
# 部署时零差异。'spread'（ΣΔ 均匀率编码，累加器+比较器）比朴素 'rate'
# （计数器+比较器，电荷挤在前 n 步）好 ~2.3pp，硬件代价相同。
MODE = 'spread'

EPOCH_TEACHER = 12
EPOCH_SCRATCH = 10
EPOCH_DISTILL = 6
BATCH = 128
LR = 1e-3
SEED = 0
SUBSET = 0                # >0 时只用前 N 个训练样本（快速迭代用）

# 蒸馏权重与超参。★ 必须"轻"：CE 是主目标，蒸馏是正则。
# 用 α=β=γ=1.0 时蒸馏项占总损失 77% → 蒸馏(70%@20dB) 反而**不如直训**；
# 降到 (0.3, 0.02, 0.1) 后蒸馏在每个 SNR 档都 ≥ 纯 CE，低 SNR 尤其明显。
ALPHA_LOGIT, BETA_MP, GAMMA_SAL = 0.3, 0.02, 0.1
TEMPERATURE = 2.0         # 温度 KL
NLD_SIGMA = 0.1           # NLD 高斯噪声强度（平滑稀疏 logits）

RESULTS = _PROJ / 'results'
CACHE = RESULTS / 'data'
CKPT_TEACHER = RESULTS / 'model_teacher_qcfs.pt'
CKPT_DISTILL = RESULTS / 'model_snn_distill.pt'
FORCE_RETRAIN_TEACHER = True   # 教师是精度上限，一次训足（改成 False 可复用缓存）


# ============================ 评估 ============================
@torch.no_grad()
def eval_teacher(model, X, y, batch=512):
    model.eval()
    preds = []
    for i in range(0, len(X), batch):
        preds.append(model(torch.from_numpy(X[i:i + batch])).argmax(1).numpy())
    preds = np.concatenate(preds)
    return float((preds == y).mean()), preds


@torch.no_grad()
def eval_snn(snn, X, y, mode=None, batch=256, inv_scale=8.0):
    """X:(N,1,128)。mode 默认取训练/部署编码 MODE。"""
    snn.eval()
    mode = MODE if mode is None else mode
    preds = []
    for i in range(0, len(X), batch):
        xT = S.encode_input(torch.from_numpy(X[i:i + batch]), T, mode, inv_scale)
        preds.append(snn(xT).argmax(1).numpy())
    preds = np.concatenate(preds)
    return float((preds == y).mean()), preds


# ============================ 三层蒸馏损失 ============================
def kd_nld_loss(logits_s, logits_t, temp=TEMPERATURE, sigma=NLD_SIGMA):
    """NLD 噪声平滑 logits 蒸馏。

    学生的 logits 是稀疏/尖峰的，与教师连续分布直接对齐是次优的；
    先加高斯噪声把分布"抹开"再算温度 KL。
    """
    if sigma > 0:
        logits_s = logits_s + torch.randn_like(logits_s) * sigma
    p_t = F.softmax(logits_t / temp, dim=1)
    log_p_s = F.log_softmax(logits_s / temp, dim=1)
    return F.kl_div(log_p_s, p_t, reduction='batchmean') * (temp ** 2)


def mp_loss(v_s, a_t):
    """膜电位蒸馏：教师末层激活 ↔ 学生末层膜电位时间平均。

    两者量纲不同（教师激活是 ReLU 尺度，学生膜电位是定点尺度），
    各按 batch 内全局 std 归一化后比 MSE——对尺度不敏感，无需额外可学习参数。
    用全局而非逐通道 std，避免某些通道方差趋 0 时把数值放大成 NaN。
    """
    a = a_t / a_t.detach().std().clamp(min=1e-6)
    v = v_s / v_s.detach().std().clamp(min=1e-6)
    return F.mse_loss(v, a)


def saliency_maps(feat2, teacher, y):
    """类感知线性化 CAM：(B,16,L) 特征图 → (B,L) 显著图。

    logit_c 关于 flatten 后特征 f 的梯度 g_c = W2[c] @ W1（线性化近似，
    忽略中间激活的非线性），reshape 成 (16,L) 后给每个空间位置加权。
    逐样本按其真实类别取 g_y，向量化实现。
    g 对教师权重 detach：它只是"给空间位置加权"的常数，不希望梯度回流到教师。
    """
    C = teacher.fc2.out_features
    g = (teacher.fc2.weight @ teacher.fc1.weight).detach().reshape(C, 16, -1)
    g_y = g[y]                                     # (B,16,L)
    return (g_y * feat2).sum(dim=1)                # (B,L)


def sal_loss(r2p_s, a2p_t, teacher, y, eps=1e-8):
    """显著性蒸馏：教师/学生各自的"关注位置分布"做 KL。

    用池化后 conv2 特征图（都是 (B,16,32)，与 fc1 输入维度对齐）：
    教师用激活图，学生用同位置的 spike 发放率图，
    各 softmax 到 32 个空间位置上的概率分布后比对——
    只要求"关注哪里"一致，不要求激活值逐元素相同（低 SNR 下更鲁棒）。
    """
    s_t = F.softmax(saliency_maps(a2p_t, teacher, y), dim=1)
    s_s = F.softmax(saliency_maps(r2p_s, teacher, y), dim=1)
    return F.kl_div((s_s + eps).log(), s_t, reduction='batchmean')


# ============================ 训练 ============================
def train_teacher(teacher, loader, X_va, y_va, epochs, tag='教师'):
    opt = torch.optim.Adam(teacher.parameters(), lr=LR)
    crit = nn.CrossEntropyLoss()
    for ep in range(1, epochs + 1):
        teacher.train()
        tot, n = 0.0, 0
        for xb, yb in loader:
            opt.zero_grad()
            loss = crit(teacher(xb), yb)
            loss.backward()
            opt.step()
            tot += loss.item() * len(xb)
            n += len(xb)
        acc, _ = eval_teacher(teacher, X_va, y_va)
        print(f'  [{tag}] epoch {ep:2d}/{epochs}: loss={tot / n:.4f} '
              f'val_acc={acc * 100:.2f}%', flush=True)


def train_snn(snn, teacher, loader, X_va, y_va, epochs, distill=False,
              tag='SNN'):
    """SNN 训练。distill=True 时加三层蒸馏；否则只做 CE（对照基线）。

    输入用 MODE 编码（=部署编码），不做 direct/rate 的域切换。
    """
    opt = torch.optim.Adam(snn.parameters(), lr=LR)
    crit = nn.CrossEntropyLoss()
    for ep in range(1, epochs + 1):
        snn.train()
        tot, n = 0.0, 0
        agg = dict(ce=0.0, kd=0.0, mp=0.0, sal=0.0)
        for xb, yb in loader:
            xT = S.encode_input(xb, T, MODE)
            opt.zero_grad()
            logits = snn(xT)
            ce = crit(logits, yb)
            loss = ce
            if distill:
                with torch.no_grad():
                    logits_t = teacher(xb)          # 填充 teacher.a1/a2/a3
                l_kd = kd_nld_loss(logits, logits_t)
                l_mp = mp_loss(snn.v3, teacher.a3)
                l_sal = sal_loss(snn.r2p, teacher.a2p, teacher, yb)
                loss = loss + ALPHA_LOGIT * l_kd + BETA_MP * l_mp \
                    + GAMMA_SAL * l_sal
                agg['kd'] += float(l_kd) * len(xb)
                agg['mp'] += float(l_mp) * len(xb)
                agg['sal'] += float(l_sal) * len(xb)
            loss.backward()
            opt.step()
            tot += float(ce) * len(xb)
            n += len(xb)
            agg['ce'] += float(ce) * len(xb)
        acc, _ = eval_snn(snn, X_va, y_va)
        extra = ''
        if distill:
            extra = (f' | kd={agg["kd"] / n:.3f} mp={agg["mp"] / n:.3f} '
                     f'sal={agg["sal"] / n:.3f}')
        print(f'  [{tag}] epoch {ep:2d}/{epochs}: ce={tot / n:.4f}'
              f'{extra} val_acc={acc * 100:.2f}%', flush=True)


# ============================ 主流程 ============================
def main():
    torch.manual_seed(SEED)
    np.random.seed(SEED)
    t0 = time.time()

    print('=' * 68, flush=True)
    print('1. 数据（复用 CNN 同缓存，保证同口径对比）', flush=True)
    print('=' * 68, flush=True)
    X, y, snr = dataset.build_train_set(2000, cache=str(CACHE))
    test_sets = dataset.build_test_sets(500, cache=str(CACHE))
    if SUBSET:
        # 分层抽样：每类取 SUBSET/5 个。数据是"按类别顺序"生成的，
        # 直接切前 SUBSET 个会得到全是第 0 类（Pulse）的退化子集。
        per = max(1, SUBSET // dataset.N_CLASSES)
        sel = np.concatenate([np.where(y == c)[0][:per]
                              for c in range(dataset.N_CLASSES)])
        X, y, snr = X[sel], y[sel], snr[sel]
    print(f'训练集 {X.shape} SNR {snr.min():.0f}~{snr.max():.0f}dB', flush=True)

    rng = np.random.default_rng(SEED)
    idx = rng.permutation(len(X))
    n_val = max(1, int(len(X) * 0.1))
    val_idx, tr_idx = idx[:n_val], idx[n_val:]
    X_tr, y_tr = X[tr_idx], y[tr_idx]
    X_va, y_va = X[val_idx], y[val_idx]
    loader = DataLoader(TensorDataset(torch.from_numpy(X_tr),
                                      torch.from_numpy(y_tr)),
                        batch_size=BATCH, shuffle=True)

    # ---------------- ① 教师 ----------------
    print('=' * 68, flush=True)
    print(f'1) 教师训练（QCFS 激活, L={QC_LEVELS}, 参数量 '
          f'{sum(p.numel() for p in S.ConvTeacher().parameters())}）', flush=True)
    print('=' * 68, flush=True)
    teacher = S.ConvTeacher(act='qcfs', qcfs_L=QC_LEVELS)
    if CKPT_TEACHER.exists() and not FORCE_RETRAIN_TEACHER:
        teacher.load_state_dict(torch.load(str(CKPT_TEACHER))['state_dict'])
        print('  从缓存载入教师权重', flush=True)
    else:
        train_teacher(teacher, loader, X_va, y_va, EPOCH_TEACHER)
        torch.save({'state_dict': teacher.state_dict()}, str(CKPT_TEACHER))
        print(f'  已保存 {CKPT_TEACHER}', flush=True)
    teacher.eval()
    # 教师按 SNR 的准确率就是这个项目的"精度上限"，先打出来便于及早发现异常
    print('  教师按 SNR 的识别率（精度上限）:', flush=True)
    for s in sorted(test_sets.keys()):
        Xs, ys = test_sets[s]
        a, _ = eval_teacher(teacher, Xs, ys)
        print(f'    SNR={s:4d}dB: {a * 100:5.2f}%', flush=True)

    # ---------------- ② SNN 直训（对照） ----------------
    print('=' * 68, flush=True)
    print('2) SNN 直训（随机初始化 + 代理梯度 BPTT + CE，无教师）', flush=True)
    print('=' * 68, flush=True)
    mk = lambda: S.ConvSNN(T=T, leak_shift=LEAK_SHIFT, hard_reset=HARD_RESET,
                           use_qat=QAT, w_bits=W_BITS, v_bits=V_BITS,
                           thr_bits=THR_BITS)
    snn_scratch = mk()
    print(f'  SNN 参数量 {sum(p.numel() for p in snn_scratch.parameters())}, '
          f'T={T}, leak_shift={LEAK_SHIFT}, QAT={QAT}', flush=True)
    train_snn(snn_scratch, teacher, loader, X_va, y_va, EPOCH_SCRATCH,
              distill=False, tag='直训')

    # ---------------- ③ 转换初始化 ----------------
    print('=' * 68, flush=True)
    print('3) 转换初始化（QCFS 解析式：拷贝权重 + λ/8 定阈值 + 折算权重，不训练）',
          flush=True)
    print('=' * 68, flush=True)
    snn_conv_init = mk()
    S.init_from_teacher(snn_conv_init, teacher)
    ths = S.convert_from_qcfs_teacher(snn_conv_init, teacher)
    print(f'  教师 QCFS clip 值 λ = '
          f'{["%.4f" % float(a.lam) for a in (teacher.act1, teacher.act2, teacher.act3)]}',
          flush=True)
    print(f'  学生 LIF 阈值 th = λ/8 = {["%.4f" % t for t in ths]}', flush=True)
    acc_c, _ = eval_snn(snn_conv_init, X_va, y_va)
    print(f'  转换初始化后 val_acc = {acc_c * 100:.2f}%', flush=True)

    # ---------------- ④ 三项蒸馏微调 ----------------
    print('=' * 68, flush=True)
    print(f'4) 三层蒸馏微调（α_logit={ALPHA_LOGIT} β_mp={BETA_MP} '
          f'γ_sal={GAMMA_SAL} τ={TEMPERATURE} σ_nld={NLD_SIGMA}）', flush=True)
    print('=' * 68, flush=True)
    snn_distill = mk()
    snn_distill.load_state_dict(snn_conv_init.state_dict())   # 从 ③ 的起点继续
    train_snn(snn_distill, teacher, loader, X_va, y_va, EPOCH_DISTILL,
              distill=True, tag='蒸馏')

    # ---------------- 按 SNR 汇总 ----------------
    print('=' * 68, flush=True)
    print(f'5) 按 SNR 评估（同一测试集，{MODE} 脉冲输入，同口径）', flush=True)
    print('=' * 68, flush=True)
    snrs = sorted(test_sets.keys())
    rows = {k: [] for k in ('teacher', 'scratch', 'conv_init', 'distill')}
    hdr = f'{"SNR(dB)":>8} {"教师":>9} {"SNN直训":>9} {"转换初始化":>11} {"蒸馏":>9}'
    print(hdr, flush=True)
    for s in snrs:
        Xs, ys = test_sets[s]
        rows['teacher'].append(eval_teacher(teacher, Xs, ys)[0])
        rows['scratch'].append(eval_snn(snn_scratch, Xs, ys)[0])
        rows['conv_init'].append(eval_snn(snn_conv_init, Xs, ys)[0])
        rows['distill'].append(eval_snn(snn_distill, Xs, ys)[0])
        print(f'{s:8d} {rows["teacher"][-1] * 100:8.2f}% '
              f'{rows["scratch"][-1] * 100:8.2f}% '
              f'{rows["conv_init"][-1] * 100:10.2f}% '
              f'{rows["distill"][-1] * 100:8.2f}%', flush=True)

    # ---------------- 编码方式对照（部署口径验证） ----------------
    print('=' * 68, flush=True)
    print(f'6) 部署口径验证：模型全程只在 {MODE} 域训练，下表换编码测"域外"表现',
          flush=True)
    print('=' * 68, flush=True)
    print(f'{"SNR(dB)":>8} {"spread·部署":>12} {"direct·模拟":>12} {"rate·朴素":>11}',
          flush=True)
    spikes = {k: [] for k in ('spread', 'direct', 'rate')}
    for s in snrs:
        Xs, ys = test_sets[s]
        for m in spikes:
            spikes[m].append(eval_snn(snn_distill, Xs, ys, mode=m)[0])
        print(f'{s:8d} {spikes["spread"][-1] * 100:11.2f}% '
              f'{spikes["direct"][-1] * 100:11.2f}% '
              f'{spikes["rate"][-1] * 100:10.2f}%', flush=True)
    gap_d = np.mean([spikes['direct'][i] - spikes['spread'][i]
                     for i in range(len(snrs))]) * 100
    gap_r = np.mean([spikes['spread'][i] - spikes['rate'][i]
                     for i in range(len(snrs))]) * 100
    print(f'  spread(训练域) vs direct(模拟电流): {gap_d:+.2f} pp '
          f'→ 脉冲化本身几乎不掉点', flush=True)
    print(f'  spread(训练域) vs rate(域外,未训练): {gap_r:+.2f} pp '
          f'→ 这个差值衡量的是"域不一致"的代价，不是两种编码本身的优劣。', flush=True)
    print('  ★ 同域公平对比（各自用自己编码训练，见消融）：spread 89.4% vs '
          'rate 87.2% @20dB，差 ~2.2pp。', flush=True)

    # ---------------- 保存 ----------------
    torch.save({'state_dict': snn_distill.state_dict(), 'T': T,
                'mode': MODE, 'leak_shift': LEAK_SHIFT,
                'hard_reset': HARD_RESET, 'thresholds': ths,
                'snr_grid': snrs, 'accs': rows['distill'],
                'encodings': spikes}, str(CKPT_DISTILL))
    _save_report(rows, snrs, spikes)

    # 10dB 混淆矩阵
    Xs, ys = test_sets[10]
    _, pred = eval_snn(snn_distill, Xs, ys)
    cm = np.zeros((5, 5), int)
    for r in range(5):
        for c in range(5):
            cm[r, c] = ((ys == r) & (pred == c)).sum()
    print(f'\n蒸馏 SNN @10dB 混淆矩阵 (行=真实, 列=预测) {dataset.SIGNAL_TYPES}:',
          flush=True)
    print(cm, flush=True)
    print(f'\n总耗时 {time.time() - t0:.1f}s', flush=True)


def _save_report(rows, snrs, spikes):
    RESULTS.mkdir(exist_ok=True)
    lines = [f'# 训练/部署编码 = {MODE}（脉冲输入）；T={T}, QAT={QAT}, '
             f'蒸馏权重 α={ALPHA_LOGIT} β={BETA_MP} γ={GAMMA_SAL}',
             '# spread/direct/rate 三列 = 同一个(只在 spread 域训练过的)模型换编码评估。',
             '# 其中 rate 是"域外"评估，低分反映的是编码域不一致，不是编码本身优劣；',
             '# 同域公平对比另见消融：spread 89.4% vs rate 87.2% @20dB（差 ~2.2pp）。',
             'SNR(dB),教师,SNN直训,转换初始化,SNN蒸馏,spread,direct,rate']
    for i, s in enumerate(snrs):
        lines.append(
            f'{s},{rows["teacher"][i]:.4f},{rows["scratch"][i]:.4f},'
            f'{rows["conv_init"][i]:.4f},{rows["distill"][i]:.4f},'
            f'{spikes["spread"][i]:.4f},{spikes["direct"][i]:.4f},'
            f'{spikes["rate"][i]:.4f}')
    txt = RESULTS / 'distill_compare.txt'
    txt.write_text('\n'.join(lines), encoding='utf-8')
    print(f'对比表已保存: {txt}', flush=True)

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        plt.figure(figsize=(7.5, 5))
        for k, lab, st in (('teacher', '教师 CNN (QCFS, 模拟)', 'k-'),
                           ('scratch', 'SNN 直训（无初始化/无蒸馏）', 's--'),
                           ('conv_init', 'SNN 转换初始化（不训练）', '^:'),
                           ('distill', f'SNN 蒸馏（{MODE} 脉冲输入）', 'D-')):
            plt.plot(snrs, np.array(rows[k]) * 100, st, lw=2, label=lab)
        plt.plot(snrs, np.array(spikes['direct']) * 100, 'v-.', lw=1.2,
                 color='gray', label='SNN 蒸馏 + direct 模拟电流（上限）')
        plt.xlabel('SNR (dB)')
        plt.ylabel('识别率 (%)')
        plt.ylim(0, 105)
        plt.grid(True, alpha=0.3)
        plt.legend(fontsize=8)
        plt.title(f'雷达信号识别率 vs SNR：CNN教师 → QCFS转换 → {MODE}脉冲域蒸馏')
        plt.tight_layout()
        plt.savefig(str(RESULTS / 'distill_compare.png'), dpi=150)
        print(f'曲线已保存: {RESULTS / "distill_compare.png"}', flush=True)
    except Exception as e:
        print(f'[提示] 画图失败（不影响训练）: {e}', flush=True)


if __name__ == '__main__':
    main()
