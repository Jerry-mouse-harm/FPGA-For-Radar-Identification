# hw/board/Makefile —— 上板开源流 (yosys -> nextpnr-himbaechel -> gowin_pack -> openFPGALoader)
# 用法: source ~/tools/oss-cad-suite/environment && make && make load
CHIP   := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C          # C 器件这里填"家族"而不是完整型号
BOARD  := tangnano20k

SRC    := blink/blink_led.v
CST    := blink/blink_led.cst
TOP    := top

all: blink_led.fs

blink_led.json: $(SRC)
	yosys -p "synth_gowin -json blink_led.json -family gw2a -top $(TOP)" $(SRC)

blink_led_pnr.json: blink_led.json
	nextpnr-himbaechel --device $(CHIP) \
	    --vopt family=$(FAMILY) --vopt cst=$(CST) \
	    --json blink_led.json --write blink_led_pnr.json

blink_led.fs: blink_led_pnr.json
	gowin_pack -d $(FAMILY) -o blink_led.fs blink_led_pnr.json

# 下到 SRAM (掉电即失, 用于快速验证)
load: blink_led.fs
	openFPGALoader -b $(BOARD) blink_led.fs

# 固化到 flash (掉电保留)
flash: blink_led.fs
	openFPGALoader -b $(BOARD) -f blink_led.fs

clean:
	rm -f *.json *.fs
