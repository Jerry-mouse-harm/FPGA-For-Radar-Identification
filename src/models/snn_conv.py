# -*- coding: utf-8 -*-
"""
src/models/snn_conv.py —— 硬件对齐的 Conv-SNN 学生 + QCFS 教师
================================================================
与 v1 的 1D-CNN 基线 RadarCNN1D（已删除，见 LOG.md 第 3 节）逐层同构，
这样才能做"层对层"的特征蒸馏 / 膜电位蒸馏 / 显著性蒸馏。

为什么不用 SpikingJelly 自带的 LIFNode
--------------------------------------
自带 LIF 的泄漏是浮点乘 V*(1-1/tau)，FPGA 上做不了。本项目要求在硬件上
用【移位】实现泄漏（V -= V>>k，2 的幂除法在硬件上免费），所以自己写
QuantLIF，并在训练时用 fake-quant 模拟定点，保证"软件训练 == 硬件执行"。
脉冲的代理梯度直接复用 SpikingJelly 的 surrogate.ATan（纯 autograd Function，
不含任何动力学，可以安全借用）。

网络结构（教师 / 学生逐层对应）
------------------------------
    Conv1d(1→8, k5, p2)   → Act → MaxPool(2)     128 → 64   特征图 (B,8,64)
    Conv1d(8→16, k5, p2)  → Act → MaxPool(2)      64 → 32   特征图 (B,16,32)
    Flatten → Linear(512→32) → Act                            (B,32)
    Linear(32→5)                                              (B,5)

    教师 Act = QCFS 量化激活（有界 → 转换误差 O(1/L)，见 Fang et al. NeurIPS'21）
    学生 Act = QuantLIF（脉冲）；池化作用在 0/1 脉冲上 = OR 门（硬件免费）

权重按 int8 做 fake-quant（STE 直通梯度），膜电位按 int16、阈值按 int8 同理，
均由开关控制，便于"先提 ACC 再收紧位宽"。
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

from spikingjelly.activation_based import surrogate


# ============================================================================
# 一、定点 fake-quant（前向量化、反向 STE 直通）
# ============================================================================
class _STE(torch.autograd.Function):
    """直通估计器：前向返回量化值，反向把梯度原样传回未量化张量。"""

    @staticmethod
    def forward(ctx, x, xq):
        return xq

    @staticmethod
    def backward(ctx, g):
        return g, None


def fake_quant_sym(x, bits, scale=None):
    """对称定点量化（含符号位），梯度用 STE。

    bits：总位宽，例如 8 → 取值 [-128, 127]
    scale：定点步长（LSB）。None 时按当前张量的最大绝对值自动定标
           （训练方便；真部署时应改为标定一次的固定常数）
    """
    if not bits or bits <= 0:
        return x
    qmax = 2 ** (bits - 1) - 1
    if scale is None:
        ## 这种计算scale的方法可能由于离群点的出现，使得其他的值被压在0附近，因此后面引入了取0.99分位数的方法
        scale = x.detach().abs().amax().clamp(min=1e-8) / qmax
    xq = torch.clamp(torch.round(x / scale), -qmax - 1, qmax) * scale
    return _STE.apply(x, xq)


def _wq(w, use_qat, bits):
    """权重 fake-quant 薄封装（每个 forward 动态定标，QAT 常用做法）。"""
    return fake_quant_sym(w, bits) if use_qat else w


def high_quantile(x, q=0.999):
    """取高分位数（比 max 抗离群点），用于阈值标定。"""
    xf = x.detach().abs().flatten()
    n = xf.numel()
    k = max(1, min(n, int(q * n)))
    return xf.kthvalue(k).values


def _inv_softplus(y):
    """softplus 的反函数，用于按目标阈值初始化参数（阈值恒正）。

    y 很大时 expm1 会溢出，此时 softplus(x)≈x（x>30 时误差 <1e-13），直接返回 y。
    """
    y = float(y)
    if y > 30.0:
        return torch.tensor(y)
    return torch.log(torch.expm1(torch.tensor(max(y, 1e-6))))


# ============================================================================
# 二、输入编码（硬件：移位 + 加法 + 钳位；无随机数）
# ============================================================================
def encode_input(x, T, mode='direct', inv_scale=8.0):
    """标准化信号 x:(B,1,L) → 输入编码 (T,B,1,L)。

    x01 = clamp(x/inv_scale + 0.5, 0, 1)   定点仿射映射到 [0,1]，脉冲幅度恒为 1
    （硬件端"脉冲×权重"退化为条件加法 → 免乘法器）。
        direct：每步注入电流 = x01          （模拟电流，训练友好；数字端需乘法器）
        rate  ：s[t] = (t < n)              （计数器+比较器，前 n 步连发）
        spread：累加器 n 溢出即发           （ΣΔ/Bresenham，均匀铺开）

    rate 与 spread 的总电荷完全相同（都等于 n = round(x01·T)），差别只在时间分布：
    rate 把电荷挤在前 n 步（t=0 时全部元素同时起爆，电流随时间衰减），
    spread 把 n 个脉冲均匀铺满 T 步（瞬时电流平稳、无起始冲击，时间上更接近恒流）。
    两者直流分量（x01 均值 0.5）都已由转换初始化折进 b1'，不额外占资源。
    注意：任何 0/1 编码的单步电流都存在 ±0.5·|W1| 量级的量化抖动（与 T 无关），
    所以单步峰值仍可能超过阈值 → 每步一步一脉冲的 LIF 会少量丢电荷。这是"脉冲域
    编码"相对"模拟电流"的固有代价，靠少量 epoch 的脉冲域微调补偿。
    """
    x01 = (x / inv_scale + 0.5).clamp(0.0, 1.0)              # (B,1,L)
    if mode == 'direct':
        return x01.unsqueeze(0).expand(T, *x01.shape).contiguous()
    n = torch.round(x01 * T)                                 # (B,1,L) 整数脉冲数
    if mode == 'rate':
        t = torch.arange(T, device=x.device).view(T, 1, 1, 1)
        return (t < n.unsqueeze(0)).to(x01.dtype)
    if mode == 'spread':
        # 硬件：acc += n; s = (acc >= T); acc -= s*T   （一个累加器 + 比较器）
        # 闭式等价：第 t 步发放 iff floor((t+1)·n/T) - floor(t·n/T) = 1
        # （acc_t = (t·n) mod T），向量化后无循环，训练时开销可忽略。
        t = torch.arange(T, device=x.device, dtype=x01.dtype).view(T, 1, 1, 1)
        nn_ = n.unsqueeze(0)                                 # (1,B,1,L)
        return torch.floor((t + 1) * nn_ / T) - torch.floor(t * nn_ / T)
    raise ValueError(f'未知编码模式: {mode}')


def _pool(x, k=2):
    """对 (T,B,C,L) 在长度维做最大池化。作用在 0/1 脉冲上 = OR 门。"""
    T, B, C, L = x.shape
    y = F.max_pool1d(x.reshape(T * B, C, L), k)
    return y.reshape(T, B, C, y.shape[-1])


# ============================================================================
# 三、硬件对齐的 LIF 神经元
# ============================================================================
class QuantLIF(nn.Module):
    """与 RTL 行为一致的 LIF（多步模式，输入形状 (T,B,...)）。

    硬件每个时间步（全部定点）：
        V = V - (V >> LEAK_SHIFT)     # 泄漏用移位，2 的幂除法免费
        V = V + X[t]                  # 突触电流累加（脉冲×权重 → 纯加法）
        V = quantize(V)               # 膜电位寄存器有有限位宽
        S = (V >= Vth)                # 比较器
        V = V - Vth * S               # 软复位（减法器）
                                      # 硬复位则为 V = 0

    store_trace=True 时记录膜电位轨迹 self.v_trace (T,B,...)，供膜电位蒸馏 /
    阈值标定使用（默认关闭以省显存）。
    """

    def __init__(self, leak_shift=1, v_threshold=1.0, hard_reset=False,
                 use_qat=True, v_bits=16, thr_bits=8, store_trace=False):
        super().__init__()
        self.leak_shift = int(leak_shift)       # 0 → 无泄漏（IF）
        self.hard_reset = bool(hard_reset)
        self.use_qat = bool(use_qat)
        self.v_bits = v_bits
        self.thr_bits = thr_bits
        self.store_trace = store_trace
        self.v_threshold_raw = nn.Parameter(_inv_softplus(v_threshold))
        self.spike_fn = surrogate.ATan()
        self.v_trace = None

    # 阈值恒正，用 softplus 参数化（梯度干净，导出时算一次 softplus 即可）
    @property
    def v_threshold(self):
        return F.softplus(self.v_threshold_raw) + 1e-3

    @v_threshold.setter
    def v_threshold(self, val):
        with torch.no_grad():
            self.v_threshold_raw.fill_(_inv_softplus(float(val) - 1e-3))

    def forward(self, x):
        T = x.shape[0]
        v = torch.zeros_like(x[0])
        th = fake_quant_sym(self.v_threshold, self.thr_bits) if self.use_qat \
            else self.v_threshold
        spikes, traj = [], []
        for t in range(T):
            if self.leak_shift > 0:
                v = v - v / (2 ** self.leak_shift)          # == V - (V >> k)
            v = v + x[t]
            if self.use_qat and self.v_bits:
                v = fake_quant_sym(v, self.v_bits)          # 膜电位寄存器位宽
            s = self.spike_fn(v - th)
            v = v * (1.0 - s) if self.hard_reset else v - th * s
            spikes.append(s)
            if self.store_trace:
                traj.append(v)
        self.v_trace = torch.stack(traj) if self.store_trace else None
        return torch.stack(spikes)


# ============================================================================
# 四、QCFS 量化激活（教师用）
# ============================================================================
def quant_qcfs(a, L, lam):
    """QCFS：a_q = (lam/L) * clip(round(a*L/lam), 0, L)，梯度 STE。"""
    aq = torch.clamp(torch.round(a * L / lam), 0, L) * (lam / L)
    return _STE.apply(a, aq)


class QCFSAct(nn.Module):
    """QCFS 量化激活。训练时用高分位数在线标定 clip 上限 lam（标准量化标定做法）。"""

    def __init__(self, L=16, init_lam=4.0, momentum=0.9):
        super().__init__()
        self.L = int(L)
        self.momentum = momentum
        self.register_buffer('lam', torch.tensor(float(init_lam)))

    def forward(self, a):
        if self.training:
            with torch.no_grad():
                m = high_quantile(a, 0.999).clamp(min=1e-6)
                self.lam.mul_(self.momentum).add_((1 - self.momentum) * m)
        return quant_qcfs(a, self.L, self.lam.clamp(min=1e-6))


# ============================================================================
# 五、教师网络（与 ConvSNN 逐层同构）
# ============================================================================
class ConvTeacher(nn.Module):
    """雷达信号教师网络。act='qcfs'（推荐，激活有界利于转换）或 'relu'。

    前向缓存 a1/a2/a3（各层激活）供蒸馏使用：
        a1 (B,8,64)   a2 (B,16,32)   a3 (B,32)
    """

    def __init__(self, n_points=128, n_classes=5, act='qcfs', qcfs_L=16,
                 dropout=0.0):
        super().__init__()
        self.conv1 = nn.Conv1d(1, 8, kernel_size=5, padding=2)
        self.conv2 = nn.Conv1d(8, 16, kernel_size=5, padding=2)
        pooled = n_points // 4
        self.fc1 = nn.Linear(16 * pooled, 32)
        self.fc2 = nn.Linear(32, n_classes)
        self.dropout = nn.Dropout(dropout)

        def mk_act():
            return QCFSAct(L=qcfs_L) if act == 'qcfs' else nn.ReLU()

        self.act1, self.act2, self.act3 = mk_act(), mk_act(), mk_act()
        self.a1 = self.a2 = self.a2p = self.a3 = None

    def forward(self, x):
        """x: (B,1,L) 模拟信号。

        缓存 a1 (B,8,128) / a2 (B,16,64) 为池化前激活图；a2p (B,16,32) 为池化后
        —— a2p 与 fc1 的输入维度对齐，显著性蒸馏用它与学生的池化后发放率图比对。
        """
        a1 = self.act1(self.conv1(x))
        a2 = self.act2(self.conv2(F.max_pool1d(a1, 2)))
        a2p = F.max_pool1d(a2, 2)
        a3 = self.act3(self.fc1(a2p.flatten(1)))
        self.a1, self.a2, self.a2p, self.a3 = a1, a2, a2p, a3
        return self.fc2(self.dropout(a3))


# ============================================================================
# 六、Conv-SNN 学生
# ============================================================================
class ConvSNN(nn.Module):
    """与 ConvTeacher 逐层同构的脉冲网络。

    forward 后缓存（形状与教师 a1/a2/a2p/a3 逐层对齐，便于蒸馏）：
        r1  (B,8,128)  r2 (B,16,64)  池化前平均发放率
        r2p (B,16,32)                池化后平均发放率（显著性蒸馏用）
        r3  (B,32)                   末层平均发放率
        v3  (B,32)     LIF3 膜电位时间平均（膜电位蒸馏用）
        logits (B,5)   由 r3 经 fc2 读出（脉冲率读出，与 QCFS 理论一致）
    """

    def __init__(self, n_points=128, n_classes=5, T=16, leak_shift=1,
                 hard_reset=False, use_qat=True, w_bits=8, v_bits=16,
                 thr_bits=8):
        super().__init__()
        self.T = T
        self.use_qat, self.w_bits = use_qat, w_bits
        self.conv1 = nn.Conv1d(1, 8, kernel_size=5, padding=2)
        self.conv2 = nn.Conv1d(8, 16, kernel_size=5, padding=2)
        pooled = n_points // 4
        self.fc1 = nn.Linear(16 * pooled, 32)
        self.fc2 = nn.Linear(32, n_classes)

        lif_kw = dict(leak_shift=leak_shift, hard_reset=hard_reset,
                      use_qat=use_qat, v_bits=v_bits, thr_bits=thr_bits)
        self.lif1 = QuantLIF(v_threshold=1.0, **lif_kw)
        self.lif2 = QuantLIF(v_threshold=1.0, **lif_kw)
        # 末层常开膜电位轨迹记录（(T,B,32) 很小），膜电位蒸馏依赖它
        self.lif3 = QuantLIF(v_threshold=1.0, store_trace=True, **lif_kw)

        self.r1 = self.r2 = self.r2p = self.r3 = self.v3 = self.logits = None

    # ---- 逐层前向（拆开是为了阈值标定能复用同一套代码）----
    def _l1(self, xT):
        w = _wq(self.conv1.weight, self.use_qat, self.w_bits)
        T, B, L = xT.shape[0], xT.shape[1], xT.shape[-1]
        return F.conv1d(xT.reshape(-1, 1, L), w, self.conv1.bias,
                        padding=2).reshape(T, B, 8, -1)

    def _l2(self, p1):
        w = _wq(self.conv2.weight, self.use_qat, self.w_bits)
        T, B, L = p1.shape[0], p1.shape[1], p1.shape[-1]
        return F.conv1d(p1.reshape(-1, 8, L), w, self.conv2.bias,
                        padding=2).reshape(T, B, 16, -1)

    def _l3(self, p2):
        w = _wq(self.fc1.weight, self.use_qat, self.w_bits)
        T, B = p2.shape[0], p2.shape[1]
        return F.linear(p2.reshape(T, B, -1), w, self.fc1.bias)

    def forward(self, xT):
        """xT: (T,B,1,L) 输入编码。返回 logits (B,n_classes)。"""
        s1 = self.lif1(self._l1(xT)); p1 = _pool(s1)
        s2 = self.lif2(self._l2(p1)); p2 = _pool(s2)
        s3 = self.lif3(self._l3(p2))

        self.r1, self.r2 = s1.mean(0), s2.mean(0)
        self.r2p, self.r3 = p2.mean(0), s3.mean(0)
        self.v3 = self.lif3.v_trace.mean(0) if self.lif3.v_trace is not None \
            else self.r3
        self.logits = F.linear(self.r3,
                               _wq(self.fc2.weight, self.use_qat, self.w_bits),
                               self.fc2.bias)
        return self.logits


# ============================================================================
# 七、转换初始化：拷贝权重 + 逐层阈值标定
# ============================================================================
@torch.no_grad()
def init_from_teacher(student, teacher):
    """把教师权重逐层拷进学生（转换初始化的第一步）。"""
    for name in ('conv1', 'conv2', 'fc1', 'fc2'):
        getattr(student, name).weight.copy_(getattr(teacher, name).weight)
        getattr(student, name).bias.copy_(getattr(teacher, name).bias)


@torch.no_grad()
def _search_threshold(lif, a, target_rate, iters=16):
    """对数空间二分阈值，使该层平均发放率 ≈ target_rate。

    发放率随阈值单调递减，但阈值常跨数量级（1e-3 ~ 1e3），所以在对数空间二分。
    """
    lo, hi = 1e-6, 1.0
    for _ in range(40):                       # 先扩张上界把目标夹住
        lif.v_threshold = hi
        if lif(a).mean().item() < target_rate:
            break
        lo, hi = hi, hi * 4.0
    for _ in range(iters):
        mid = (lo * hi) ** 0.5
        lif.v_threshold = mid
        if lif(a).mean().item() > target_rate:
            lo = mid
        else:
            hi = mid
    lif.v_threshold = hi
    return float(hi)


def _pick_threshold(lif, a, target_rates, idx, q):
    """有目标发放率用二分搜索；否则退化为膜电位高分位数。"""
    if target_rates is not None:
        return _search_threshold(lif, a, float(target_rates[idx]))
    store_was = lif.store_trace
    lif.store_trace = True
    lif.v_threshold = 1e4
    lif(a)
    th = float(high_quantile(lif.v_trace, q))
    lif.v_threshold = th
    lif.store_trace = store_was
    return th


@torch.no_grad()
def fold_input_affine(student, inv_scale=8.0, shift=0.5):
    """把输入编码的仿射变换 x01 = x/inv_scale + shift 折算进第 1 层卷积。

    学生第一层实际吃的是 x01∈[0,1]，而教师是按原始标准化信号 x 训练的。
    直接喂 x01 会给每个通道引入一个直流偏置 shift·ΣW1，它比信号部分
    W1·x/inv_scale 大一个数量级 → 发放率被直流主导，判别信息被淹没（实测转换后
    只有 20%，即随机猜）。

    目标：让学生第一层输出 = 教师第一层输出 / inv_scale（纯缩放、无直流），
    这个均匀缩放会被阈值标定自然吸收。由 x01 = x/inv_scale + shift 推导：
        W1' = W1
        b1' = b1 / inv_scale - shift * Σ_k W1[c,0,k]
    验证：W1·(x/8+0.5) + b1/8 - 0.5ΣW1 = W1·x/8 + b1/8 = a1/8  ✓

    必须在 init_from_teacher 之后、balance_thresholds 之前调用。
    """
    W = student.conv1.weight                       # (8,1,5)
    student.conv1.bias.div_(inv_scale).sub_(shift * W.sum(dim=(1, 2)))


@torch.no_grad()
def convert_from_qcfs_teacher(student, teacher, inv_scale=8.0, shift=0.5):
    """QCFS 解析式转换初始化（不用校准搜索，无过拟合风险）。

    输入编码把信号搬到 x01 = x/inv_scale + shift ∈[0,1]（脉冲编码的必要条件），
    于是整个学生网络都运行在 1/inv_scale 的尺度上。转换规则：

        W1 不变;  b1 = b1/inv_scale - shift*ΣW1   # 抵消 x01 引入的直流
        b2,b3,b4 = b_l / inv_scale                 # 整个网络统一缩放到 1/inv_scale
        th_l = λ_l / inv_scale                     # λ_l 是教师第 l 层 QCFS 的 clip 值
        W_{l+1} *= th_l                            # 把"发放率→激活"的尺度补回来

    推导（第 2 层为例，a_l 为教师激活、r_l 为学生发放率、z 为预激活）：
        学生 z2' = th1·W2@r1 + b2'，而 r1 = a1_student/th1 = (a1/8)/(λ1/8) = a1/λ1
                = W2@a1/8 + b2'
        教师 z2/8 = W2@a1/8 + b2/8
        ⇒ b2' = b2/8 且 th1 = λ1/8。逐层递推即得通用规则。
        末层 logits = 教师 logits / 8（全局常数，argmax 不变）。

    注意：这是"一次性"转换，不要重复调用（会重复缩放权重）。
    """
    assert hasattr(teacher.act1, 'lam'), 'QCFS 转换要求教师使用 QCFSAct'
    fold_input_affine(student, inv_scale, shift)          # W1 不变，只改 b1
    for name in ('conv2', 'fc1', 'fc2'):
        getattr(student, name).bias.div_(inv_scale)

    ths = [float(teacher.act1.lam) / inv_scale,
           float(teacher.act2.lam) / inv_scale,
           float(teacher.act3.lam) / inv_scale]
    student.lif1.v_threshold = ths[0]
    student.lif2.v_threshold = ths[1]
    student.lif3.v_threshold = ths[2]

    student.conv2.weight.mul_(ths[0])
    student.fc1.weight.mul_(ths[1])
    student.fc2.weight.mul_(ths[2])
    return ths


@torch.no_grad()
def balance_thresholds(student, x_calib, T, mode='direct', inv_scale=8.0,
                       target_rates=None, q=0.999):
    """逐层标定 LIF 阈值 + 把阈值折算进下一层权重（转换初始化的核心）。

    推荐传 target_rates：每层目标平均发放率，取教师该层"归一化激活"的均值
    （a_l / lam_l）。用二分搜索让发放率匹配，比"取激活最大值/高分位数"稳健得多
    —— 后者会把阈值顶到分布尾部，导致深层层完全死寂（发放率 0 → 代理梯度断掉）。

    ★ 只标定阈值是不够的：LIF 的输出是发放率，量级是教师的【归一化】激活
    a_l/lam_l；但教师下一层的权重是按【原始】激活 a_l 的尺度训练的。两者差一个
    lam_l≈阈值 的因子，逐层累积会把读出 logits 缩小若干个数量级，转换后的网络
    退化成常数输出（实测 20%）。所以标定完第 l 层阈值后，把第 l+1 层权重放大
    th_l 倍来抵消：
        z_{l+1} = (W_{l+1}·th_l) @ r_l + b_{l+1} ≈ W_{l+1} @ a_l + b_{l+1}
    偏置不缩放（它与激活同尺度）。这就是 Rueckauer 2017 的 weight normalization。

    逐层串行：下一层的输入依赖上一层的脉冲，所以必须一层层来。
    返回标定后的三层阈值。
    """
    xT = encode_input(x_calib, T, mode, inv_scale)
    ths = []

    a1 = student._l1(xT)
    th1 = _pick_threshold(student.lif1, a1, target_rates, 0, q)
    student.conv2.weight.mul_(th1)                 # 折算进第 2 层
    s1 = student.lif1(a1)
    ths.append(th1)

    a2 = student._l2(_pool(s1))
    th2 = _pick_threshold(student.lif2, a2, target_rates, 1, q)
    student.fc1.weight.mul_(th2)                   # 折算进第 3 层
    s2 = student.lif2(a2)
    ths.append(th2)

    a3 = student._l3(_pool(s2))
    th3 = _pick_threshold(student.lif3, a3, target_rates, 2, q)
    student.fc2.weight.mul_(th3)                   # 折算进读出层
    student.lif3(a3)
    ths.append(th3)

    return ths


@torch.no_grad()
def teacher_target_rates(teacher, x_calib):
    """教师每层"归一化激活"的均值 → SNN 各层目标发放率。

    对 QCFS 教师，激活被 clip 到 [0, lam]，故 a/lam ∈ [0,1] 正是"归一化激活"，
    也就是 SNN 转换后该层应有的平均发放率；对 ReLU 教师用 0.999 分位数当 lam。
    """
    teacher(x_calib)
    lam = []
    for act_mod, a in zip((teacher.act1, teacher.act2, teacher.act3),
                          (teacher.a1, teacher.a2, teacher.a3)):
        lam.append(act_mod.lam if hasattr(act_mod, 'lam')
                   else high_quantile(a, 0.999))
    return [(a / l.clamp(min=1e-6)).mean().item()
            for a, l in zip((teacher.a1, teacher.a2, teacher.a3), lam)]


def saliency_from_weights(teacher, class_idx):
    """用教师线性层权重的线性化梯度算"类感知显著性"的通道权重。

    对 flatten 后的 conv2 特征图 f (512,)，分类 logit 关于 f 的梯度为
        g_c = W2[c] @ W1        （去掉 ReLU 的非线性，线性化近似）
    形状 (512,) → reshape (16,32)，即可给每个空间位置加权。
    返回 (16,32)。
    """
    W1 = teacher.fc1.weight                       # (32,512)
    W2 = teacher.fc2.weight                       # (5,32)
    g = W2[class_idx] @ W1                        # (32,)@(32,512) → (512,)
    return g.reshape(16, -1)


# ============================================================================
# 八、自检
# ============================================================================
if __name__ == '__main__':
    torch.manual_seed(0)
    T, B, L = 16, 16, 128
    x = torch.randn(B, 1, L)

    teacher = ConvTeacher()
    print('教师 QCFS logits:', tuple(teacher(x).shape))
    print('教师各层激活:', tuple(teacher.a1.shape), tuple(teacher.a2.shape),
          tuple(teacher.a3.shape))

    snn = ConvSNN(T=T, leak_shift=0, use_qat=True)
    xT = encode_input(x, T, 'direct')
    print('输入编码 direct:', tuple(xT.shape),
          ' rate:', tuple(encode_input(x, T, 'rate').shape))

    print('SNN logits:', tuple(snn(xT).shape),
          ' 参数量:', sum(p.numel() for p in snn.parameters()))
    print('缓存 r1/r2/r3/v3:', tuple(snn.r1.shape), tuple(snn.r2.shape),
          tuple(snn.r3.shape), tuple(snn.v3.shape))

    init_from_teacher(snn, teacher)
    tgts = teacher_target_rates(teacher, x)
    print('教师目标发放率:', [f'{t:.3f}' for t in tgts])
    ths = balance_thresholds(snn, x, T, target_rates=tgts)
    print('标定阈值:', [f'{t:.4f}' for t in ths])
    snn(xT)
    print('标定后实际发放率:',
          f'{snn.r1.mean():.3f} {snn.r2.mean():.3f} {snn.r3.mean():.3f}')

    loss = F.cross_entropy(snn(xT), torch.randint(0, 5, (B,)))
    loss.backward()
    print('反向 OK, loss =', float(loss))
