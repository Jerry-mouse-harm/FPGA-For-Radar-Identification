# hw/engine/lif Makefile —— LIF 本地调试（本目录被 .git/info/exclude 仅本机排除）
# 仿真器指向 conda env 里的 iverilog；用 make -C hw/engine/lif 调用（CWD 必须是本目录）
CONDA := /home/jierui/miniconda3/envs/verilog-sim
IVL   := $(CONDA)/bin/iverilog
VVP   := $(CONDA)/bin/vvp
GTKW  := $(CONDA)/bin/gtkwave
PY    := /home/jierui/miniconda3/bin/python

HEX   := tb/th.hex tb/x.hex tb/spike_exp.hex tb/v_exp.hex
WROM  := rtl/conv1_wrom.v tb/conv1_weights.txt
CVEC  := tb/conv1_in.hex tb/conv1_spike_exp.hex
WROM2 := rtl/conv2_wrom.v tb/conv2_weights.txt
CVEC2 := tb/conv2_in.hex tb/conv2_spike_exp.hex
FCW   := rtl/fc1_wrom.v rtl/readout_wrom.v tb/fc1_weights.txt
FCV   := tb/fc_in.hex tb/fc_spike_exp.hex tb/fc_class_exp.hex tb/fc_logits_exp.hex
ENGV  := tb/engine_smp.hex tb/engine_cls_exp.hex tb/engine_logits_exp.hex

.PHONY: all vectors lif conv1 weights view view_conv1 \
        conv2 conv2_weights conv2_vectors view_conv2 \
        fc1 fc_weights fc_vectors readout view_fc view_readout \
        engine engine_lp4 engine_lowp engine_vectors view_engine clean

all: lif

# 重新生成金标准（纯整数，不需要 torch）
vectors:
	$(PY) tb/gen_lif_vectors.py

# 缺 hex 时自动生成一次（生成器一次写四个文件，make 顺序处理不会重复跑）
$(HEX): tb/gen_lif_vectors.py
	$(PY) tb/gen_lif_vectors.py

# 神经元判分台（24 用例 x 16 步 + 保持/异步复位）
lif: $(HEX)
	$(IVL) -g2012 -o logs/tb_lif_neuron.out tb/tb_lif_neuron.v rtl/lif_neuron.v \
	  && $(VVP) logs/tb_lif_neuron.out

# ---------------- Conv1 阵列 + 权重 ROM ----------------
# 占位合成权重（真实导出后格式不变，直接替换这两个文件）
weights:
	$(PY) tb/gen_conv1_weights.py

$(WROM): tb/gen_conv1_weights.py
	$(PY) tb/gen_conv1_weights.py

$(CVEC): tb/gen_conv1_vectors.py tb/conv1_weights.txt
	$(PY) tb/gen_conv1_vectors.py

# Conv1 判分台（10 帧 x 8 通道 x 16 步 x 128 位置）
conv1: $(WROM) $(CVEC)
	$(IVL) -g2012 -o logs/tb_conv1_array.out \
	  tb/tb_conv1_array.v rtl/conv1_array.v rtl/conv1_wrom.v \
	  && $(VVP) logs/tb_conv1_array.out

view:
	$(GTKW) logs/tb_lif_neuron.vcd &

view_conv1:
	$(GTKW) logs/tb_conv1_array.vcd &

# ---------------- Conv2 阵列 + 权重 ROM ----------------
conv2_weights:
	$(PY) tb/gen_conv2_weights.py

$(WROM2): tb/gen_conv2_weights.py
	$(PY) tb/gen_conv2_weights.py

conv2_vectors:
	$(PY) tb/gen_conv2_vectors.py

$(CVEC2): tb/gen_conv2_vectors.py tb/conv2_weights.txt
	$(PY) tb/gen_conv2_vectors.py

# Conv2 判分台（11 帧 x 16 通道 x 16 步 x 64 位置）
conv2: $(WROM2) $(CVEC2)
	$(IVL) -g2012 -o logs/tb_conv2_array.out \
	  tb/tb_conv2_array.v rtl/conv2_array.v rtl/conv2_wrom.v \
	  && $(VVP) logs/tb_conv2_array.out

view_conv2:
	$(GTKW) logs/tb_conv2_array.vcd &

# ---------------- FC1 + 读出层 ----------------
# 占位权重（真实导出后格式不变，直接替换这些文件）
fc_weights:
	$(PY) tb/gen_fc1_weights.py

$(FCW): tb/gen_fc1_weights.py
	$(PY) tb/gen_fc1_weights.py

fc_vectors:
	$(PY) tb/gen_fc_vectors.py

$(FCV): tb/gen_fc_vectors.py tb/fc1_weights.txt
	$(PY) tb/gen_fc_vectors.py

# FC1 判分台（11 帧 x 16 步 x 32 神经元）
fc1: $(FCW) $(FCV)
	$(IVL) -g2012 -o logs/tb_fc1_array.out \
	  tb/tb_fc1_array.v rtl/fc1_array.v rtl/fc1_wrom.v \
	  && $(VVP) logs/tb_fc1_array.out

# 读出层判分台（11 帧，class + logits 对拍）
readout: $(FCW) $(FCV)
	$(IVL) -g2012 -o logs/tb_readout.out \
	  tb/tb_readout.v rtl/readout.v rtl/readout_wrom.v \
	  && $(VVP) logs/tb_readout.out

view_fc:
	$(GTKW) logs/tb_fc1_array.vcd &

view_readout:
	$(GTKW) logs/tb_readout.vcd &

# ---------------- 引擎顶层端到端 ----------------
# 金标准从三份权重文本按整数模型整帧算出（真实权重装上后需重新生成）
engine_vectors:
	$(PY) tb/gen_engine_vectors.py

$(ENGV): tb/gen_engine_vectors.py tb/conv1_weights.txt tb/conv2_weights.txt tb/fc1_weights.txt
	$(PY) tb/gen_engine_vectors.py

# 9 帧端到端：encode_frontend → Conv1 → Conv2 → FC1 → readout（PW=16/LP=8）
ENGSRC := tb/tb_engine_top.v rtl/engine_top.v ../encode_frontend.v \
          ../../verilog_lab/m6_encoder/sample_to_n.v \
          rtl/conv1_array.v rtl/conv1_wrom.v rtl/conv2_array.v rtl/conv2_wrom.v \
          rtl/fc1_array.v rtl/fc1_wrom.v rtl/readout.v rtl/readout_wrom.v

engine: $(WROM) $(WROM2) $(FCW) $(ENGV)
	$(IVL) -g2012 -o logs/tb_engine_top.out $(ENGSRC) \
	  && $(VVP) logs/tb_engine_top.out

# 资源受限候选：只降 FC1 lane 数（PW 不变，无需改 RTL）
engine_lp4: $(WROM) $(WROM2) $(FCW) $(ENGV)
	$(IVL) -g2012 -DENG_LP=4 -DENG_NODUMP -o logs/tb_engine_top_lp4.out $(ENGSRC) \
	  && $(VVP) logs/tb_engine_top_lp4.out

# 资源受限候选：Conv1/Conv2 位置并行度与 FC1 lane 一起降
engine_lowp: $(WROM) $(WROM2) $(FCW) $(ENGV)
	$(IVL) -g2012 -DENG_PW1=8 -DENG_PW2=8 -DENG_LP=4 -DENG_NODUMP \
	  -o logs/tb_engine_top_lowp.out $(ENGSRC) \
	  && $(VVP) logs/tb_engine_top_lowp.out

view_engine:
	$(GTKW) logs/tb_engine_top.vcd &

clean:
	rm -f logs/*.out logs/*.vcd
