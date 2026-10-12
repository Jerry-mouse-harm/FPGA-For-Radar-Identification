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

clean:
	rm -f *.json *.fs
