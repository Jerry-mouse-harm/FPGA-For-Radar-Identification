# hw/board_bringup.md — Tang Nano 20K 上板 Runbook（WSL2 + 开源流）

> 目标：里程碑 **M0 — 在板上点亮 LED**，证明 `综合 → 布线 → 打包 → 下载` 整条链在本机跑通。
> 路线：**WSL2 开源流**（yosys / nextpnr-himbaechel / gowin_pack / openFPGALoader）+ **usbipd-win** 做 USB 直通。
> 板子：**Sipeed Tang Nano 20K**，芯片 `GW2AR-LV18QN88C8/I7`（家族 GW2A-18C），板载 27MHz 晶振。
> 调试器：板载 BL616 **模拟一颗 FTDI FT2232**，USB 枚举为 `0403:6010`（"FT2232C/D/H Dual UART/FIFO IC"）。
> openFPGALoader 把它当 `ft2232` cable，板名 `tangnano20k`。**认 `0403:6010` 就对了。**
> 仿真仍用现有 iverilog + `hw/verilog_lab/Makefile`，与本 runbook 并行、互不影响。

---

## 0. 前置检查

```bash
# WSL 里：内核要 >= 5.10.60.1，否则 usbip 不可用
uname -a
# 不满足就（Windows PowerShell，管理员）：
wsl --update
```
- 发行版建议 **Ubuntu**（Arch 等发行版 usbip 经常翻车）。
- 建议启用 systemd（让 udev/组权限正常）：`/etc/wsl.conf` 加
  ```ini
  [boot]
  systemd=true
  ```
  改完在 PowerShell `wsl --shutdown` 再进。

---

## 1. Windows 侧：装 usbipd-win 并绑定板子

```powershell
# 管理员 PowerShell，一次
winget install --interactive --exact dorssel.usbipd-win
```
> usbipd-win **4.0.0 起，WSL 侧不需要再装 usbip 客户端工具**。

插上板子后，仍用**管理员 PowerShell**：
```powershell
usbipd list                      # 找到板子对应的 BUSID（BL616 / JTAG，名字多半含 "BL616" 或 "USB Serial"）
usbipd bind   --busid <BUSID>    # 共享该设备，重启后仍有效，只需做一次
usbipd attach --wsl --busid <BUSID>   # 挂进 WSL；每次重启 WSL/插拔后都要重新 attach
```
- 记不清哪条是板子？拔掉板子跑一次 `usbipd list`，再插上跑一次，比对多出来的那条。
- 断开：`usbipd detach --busid <BUSID>`；全部断开：`usbipd detach --all`。

**WSL 里验证：**
```bash
lsusb            # 应能看到板子的 USB 设备
```
装 `kmod`（`usbipd attach` 靠它加载 `vhci-hcd`）：
```bash
sudo apt install kmod
sudo modprobe vhci-hcd     # 若报 "Loading vhci_hcd failed." 就手动加载
```

---

## 2. WSL 侧：装开源 FPGA 工具链

### 2.1 oss-cad-suite（yosis + nextpnr-himbaechel + openFPGALoader）
```bash
# 从 YosysHQ/oss-cad-suite-build 下对应平台的 nightly tar.gz，解压后 source 环境
cd ~/tools && tar xzf oss-cad-suite-linux-x64-*.tgz
source ~/tools/oss-cad-suite/environment
yosys -V && nextpnr-himbaechel --version && openFPGALoader --version
# 核对板子支持：
openFPGALoader --list-boards | grep tang     # 要能看到 tangnano20k
```
> ⚠️ **openFPGALoader 版本**：Ubuntu 的 `apt install openfpgaloader` 太旧、**不含 tangnano20k**；
> 用 oss-cad-suite 自带的那份，或从 [trabucayre/openFPGALoader](https://github.com/trabucayre/openFPGALoader) 源码编译最新版。

### 2.2 apicula（提供 `gowin_pack` + GW2AR 器件数据）
```bash
pip install apycula          # 用 oss-cad-suite 的 python，或独立的 venv
gowin_pack --help
```
> ⚠️ **版本兼容**：`apycula`（chipdb）与 `nextpnr-himbaechel` 需配套。若报器件/arch 不匹配，
> 把 `apycula` 升降到与 oss-cad-suite 同一批次的版本。

### 2.3 udev 规则（免 sudo 访问板子）
```bash
# openFPGALoader 自带 99-openfpgaloader.rules（含 0403:6010 → GROUP="plugdev", TAG+="uaccess"）
sudo cp /path/to/openFPGALoader/*/99-openfpgaloader.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo usermod -a $USER -G plugdev          # 改完重新登录/重挂设备才生效
# 重新 attach 板子（PowerShell: usbipd detach/attach --busid <BUSID>）
```
> 嫌麻烦就直接 `sudo openFPGALoader ...`。
> ⚠️ **`ftdi_sio` 冲突**：Linux 的 `ftdi_sio` 可能抢占 FT2232，导致 JTAG 找不到链路。
> 对策：`sudo rmmod ftdi_sio`，或加 udev 规则把它从该设备摘掉。

---

## 3. 点灯工程（M0）

**引脚约束别自己猜**：直接用 Sipeed 官方例程
[`TangNano-20K-example`](https://github.com/sipeed/TangNano-20K-example) 里的
`examples/blink/`（含 `blink.v` + `blink.cst` + 时钟 `.sdc`）。LED 多数是**低电平点亮**。
至少需要 `.v`（设计）+ `.cst`（引脚/时钟约束）两个文件。

目录（建议，与 `verilog_lab` 同风格）：
```
hw/board/blink/
├── blink.v
└── blink.cst      # 从官方例程拷，别手写
```

新增 Makefile target（放到 `hw/` 或 `hw/board/Makefile`）：
```make
CHIP   := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C          # 注意：C 器件这里填"家族"而不是完整型号
BOARD  := tangnano20k

all: blink.fs

blink.json:
	yosys -p "synth_gowin -json blink.json -family gw2a" blink.v

blink_pnr.json: blink.json
	nextpnr-himbaechel --device $(CHIP) \
	    --vopt family=$(FAMILY) --vopt cst=blink.cst \
	    --json blink.json --write blink_pnr.json

blink.fs: blink_pnr.json
	gowin_pack -d $(FAMILY) -o blink.fs blink_pnr.json

# 下到 SRAM（掉电即失）
load: blink.fs
	openFPGALoader -b $(BOARD) blink.fs

# 固化到 flash（掉电保留）
flash: blink.fs
	openFPGALoader -b $(BOARD) -f blink.fs

clean:
	rm -f *.json *.fs
```
看到 LED 闪 → **M0 达成**。记下各工具版本号（写进本文件底部"环境快照"）。

---

## 4. 报错对照表

| 现象 | 处置 |
|---|---|
| `usbipd: error: WSL kernel is not USBIP capable` | PowerShell `wsl --update`；换 Ubuntu 发行版 |
| `usbipd: error: Loading vhci_hcd failed` | WSL 内 `sudo apt install kmod && sudo modprobe vhci-hcd` |
| `lsusb` 看不到板子 | 重新 `usbipd attach --wsl --busid <BUSID>`（WSL 重启/插拔后需重挂） |
| `openFPGALoader` 权限错误 | 装 udev 规则 + 重挂设备，或临时 `sudo` |
| `Unable to open FTDI device: -4 (usb_open() failed)` | 装 udev 规则 + `usermod -a $USER -G plugdev` + 重挂设备 |
| `--detect` 找不到 JTAG 链路 | `ftdi_sio` 抢占 → `sudo rmmod ftdi_sio` 或 udev 里 unbind |
| `openFPGALoader` 找不到板子名 | `openFPGALoader --list-boards \| grep tang` 核对名称 |
| 板子枚举成 `0403:6010` | **正常**，BL616 模拟 FT2232，认这个 VID:PID |
| nextpnr 报器件/arch 不符 | 检查 `--device`/`--vopt family=GW2A-18C`；对齐 `apycula` 版本 |
| yosys 内存爆 | `synth_gowin -noabc9`（大设计时） |

---

## 环境快照（点灯后填）
- WSL 发行版 / 内核：
- oss-cad-suite 版本：
- apycula 版本：
- openFPGALoader 版本：
- usbipd-win 版本：
