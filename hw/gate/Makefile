# hw/gate Makefile —— 两域门控模块仿真（指向 conda env 里的 iverilog）
CONDA := /home/jierui/miniconda3/envs/verilog-sim
IVL   := $(CONDA)/bin/iverilog
VVP   := $(CONDA)/bin/vvp
GTKW  := $(CONDA)/bin/gtkwave

.PHONY: all gate view clean

all: gate

# ============ 活动检测（静息域：窗内能量 + 滞回）============
gate:
	$(IVL) -g2012 -o tb_activity_detector.out tb_activity_detector.v activity_detector.v && $(VVP) tb_activity_detector.out
	$(IVL) -g2012 -o tb_gate_ctrl.out        tb_gate_ctrl.v        gate_ctrl.v        && $(VVP) tb_gate_ctrl.out

view:
	$(GTKW) tb_activity_detector.vcd &
	$(GTKW) tb_gate_ctrl.vcd &

clean:
	rm -f *.out *.vcd
