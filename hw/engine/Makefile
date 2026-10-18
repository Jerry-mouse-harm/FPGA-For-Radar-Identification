# hw/engine Makefile —— 门控域识别引擎模块（当前：128 路编码前端）
# 仿真器指向 conda env 里的 iverilog
CONDA := /home/jierui/miniconda3/envs/verilog-sim
IVL   := $(CONDA)/bin/iverilog
VVP   := $(CONDA)/bin/vvp
GTKW  := $(CONDA)/bin/gtkwave

# 复用 M6 已验证的定点映射（不要复制/重写）
M6MAP := ../verilog_lab/m6_encoder/sample_to_n.v

.PHONY: all frontend vectors view clean

all: frontend

# 重新生成金标准（需要 torch，用 base 环境的 python）
vectors:
	/home/jierui/miniconda3/bin/python gen_vectors.py

frontend:
	$(IVL) -g2012 -o tb_encode_frontend.out tb_encode_frontend.v encode_frontend.v $(M6MAP) \
	  && $(VVP) tb_encode_frontend.out

view:
	$(GTKW) tb_encode_frontend.vcd &

clean:
	rm -f *.out *.vcd
