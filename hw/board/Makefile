# hw/board/Makefile —— 上板开源流 (yosys -> nextpnr-himbaechel -> gowin_pack -> openFPGALoader)
# 用法: source ~/tools/oss-cad-suite/environment && make && make load
CHIP   := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C          # C 器件这里填"家族"而不是完整型号
BOARD  := tangnano20k

GATE   := ../gate

# ============ 目标 1: blink (M0 点灯) ============
BSRC   := blink/blink_led.v
BCST   := blink/blink_led.cst

all: blink_led.fs

blink_led.json: $(BSRC)
	yosys -p "synth_gowin -json blink_led.json -family gw2a -top top" $(BSRC)

blink_led_pnr.json: blink_led.json
	nextpnr-himbaechel --device $(CHIP) \
	    --vopt family=$(FAMILY) --vopt cst=$(BCST) \
	    --json blink_led.json --write blink_led_pnr.json

blink_led.fs: blink_led_pnr.json
	gowin_pack -d $(FAMILY) -o blink_led.fs blink_led_pnr.json

# 下到 SRAM (掉电即失, 用于快速验证)
load: blink_led.fs
	openFPGALoader -b $(BOARD) blink_led.fs

# 固化到 flash (掉电保留)
flash: blink_led.fs
	openFPGALoader -b $(BOARD) -f blink_led.fs

# ============ 目标 3: engine_demo (真实引擎上板, LED 显示分类) ============
# 必须 -noalu：ALU 进位链会让 nextpnr 的 heap 布局器卡死在合法化
ENG    := ../engine
LIF    := $(ENG)/lif
ESRC   := engine_demo/engine_demo.v engine_demo/engine_sample_rom.v \
          $(ENG)/encode_frontend.v ../verilog_lab/m6_encoder/sample_to_n.v \
          $(LIF)/rtl/engine_top.v \
          $(LIF)/rtl/conv1_array.v $(LIF)/rtl/conv1_wrom.v \
          $(LIF)/rtl/conv2_array.v $(LIF)/rtl/conv2_wrom.v \
          $(LIF)/rtl/fc1_array.v   $(LIF)/rtl/fc1_wrom.v \
          $(LIF)/rtl/readout.v     $(LIF)/rtl/readout_wrom.v
ECST   := engine_demo/engine_demo.cst

engine_demo: engine_demo.fs

engine_demo/engine_sample_rom.v: engine_demo/gen_engine_sample_rom.py $(LIF)/tb/engine_smp.hex
	python3 engine_demo/gen_engine_sample_rom.py

engine_demo.json: $(ESRC)
	yosys -p "synth_gowin -noalu -json engine_demo.json -family gw2a -top top" $(ESRC)

engine_demo_pnr.json: engine_demo.json
	nextpnr-himbaechel --device $(CHIP) \
	    --vopt family=$(FAMILY) --vopt cst=$(ECST) \
	    --freq 27 --report engine_demo_pnr.rpt \
	    --json engine_demo.json --write engine_demo_pnr.json

engine_demo.fs: engine_demo_pnr.json
	gowin_pack -d $(FAMILY) -o engine_demo.fs engine_demo_pnr.json

load_engine: engine_demo.fs
	openFPGALoader -b $(BOARD) engine_demo.fs

flash_engine: engine_demo.fs
	openFPGALoader -b $(BOARD) -f engine_demo.fs

# 上板前仿真验接线（12 帧，验证类别序列/LED 编码/回卷）
sim_engine:
	$(IVL) -g2012 -o engine_demo/tb_engine_demo.out \
	    engine_demo/tb_engine_demo.v $(ESRC)
	$(VVP) engine_demo/tb_engine_demo.out

# ============ 目标 2: gate_demo (门控: 看 clk_eng 停跳) ============
DSRC   := gate_demo/gate_demo.v gate_demo/eng_stub.v gate_demo/signal_rom.v \
          $(GATE)/activity_detector.v $(GATE)/gate_ctrl.v
DCST   := gate_demo/gate_demo.cst

gate_demo: gate_demo.fs

gate_demo.json: $(DSRC)
	yosys -p "synth_gowin -json gate_demo.json -family gw2a -top top" $(DSRC)

gate_demo_pnr.json: gate_demo.json
	nextpnr-himbaechel --device $(CHIP) \
	    --vopt family=$(FAMILY) --vopt cst=$(DCST) \
	    --json gate_demo.json --write gate_demo_pnr.json

gate_demo.fs: gate_demo_pnr.json
	gowin_pack -d $(FAMILY) -o gate_demo.fs gate_demo_pnr.json

demo: gate_demo.fs
load_demo: gate_demo.fs
	openFPGALoader -b $(BOARD) gate_demo.fs

# 上板前先仿真验接线（conda iverilog）
CONDA  := /home/jierui/miniconda3/envs/verilog-sim
IVL    := $(CONDA)/bin/iverilog
VVP    := $(CONDA)/bin/vvp
sim_demo:
	$(IVL) -g2012 -o gate_demo/tb_gate_demo.out gate_demo/tb_gate_demo.v \
	    gate_demo/gate_demo.v gate_demo/eng_stub.v gate_demo/signal_rom.v \
	    $(GATE)/activity_detector.v $(GATE)/gate_ctrl.v
	$(VVP) gate_demo/tb_gate_demo.out

# ============ 两级唤醒 A/B 测量（TOT WuRx + 定时占空比）============
sim_two_stage:
	$(IVL) -g2012 -o gate_demo/tb_two_stage.out \
	    -DSNR_DB=20 -DW1=8 -DLISTEN=8 -DPERIOD=16 -DHOLD=32 -DNF_RISE_SH=7 \
	    gate_demo/tb_two_stage.v gate_demo/eng_stub.v gate_demo/signal_rom.v \
	    $(GATE)/activity_detector.v $(GATE)/gate_ctrl.v \
	    $(GATE)/wakeup_wu.v $(GATE)/two_stage_detector.v
	$(VVP) gate_demo/tb_two_stage.out

sweep_two_stage:
	bash gate_demo/sweep_two_stage.sh

clean:
	rm -f *.json *.fs *.rpt engine_demo/*.out
