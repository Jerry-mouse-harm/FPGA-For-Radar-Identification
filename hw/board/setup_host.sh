#!/usr/bin/env bash
# hw/board/setup_host.sh —— WSL 烧录环境一次性配置
#   (1) 装 openFPGALoader udev 规则 -> 免 sudo 访问板子
#   (2) 把用户加入 plugdev 组
#   (3) 把 oss-cad-suite 环境写进 ~/.bashrc
# 用法: bash hw/board/setup_host.sh      (中途会要 sudo 密码)
set -e

OCC="$HOME/tools/oss-cad-suite"
LINE='source ~/tools/oss-cad-suite/environment'

echo "==> [1/4] 检查 oss-cad-suite"
if [ ! -f "$OCC/environment" ]; then
    echo "找不到 $OCC/environment —— 先装 oss-cad-suite"; exit 1
fi
# shellcheck disable=SC1091
source "$OCC/environment"
command -v openFPGALoader >/dev/null || { echo "openFPGALoader 不在 PATH"; exit 1; }
echo "ok: $(openFPGALoader --version | head -1)"

echo "==> [2/4] 安装 udev 规则 (Tang Nano 20K / FT2232 = 0403:6010)"
RULE_FILE=/etc/udev/rules.d/99-tangnano.rules
sudo tee "$RULE_FILE" >/dev/null <<'RULE'
# Tang Nano 20K 调试器 (BL616 模拟 FTDI FT2232), 让 openFPGALoader 免 sudo 访问
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", MODE="0666", GROUP="plugdev", TAG+="uaccess"
RULE
sudo udevadm control --reload-rules
sudo udevadm trigger
echo "已写入 $RULE_FILE"

echo "==> [3/4] 用户加入 plugdev 组"
sudo usermod -aG plugdev "$USER"

echo "==> [4/4] 写入 ~/.bashrc"
if grep -qxF "$LINE" "$HOME/.bashrc" 2>/dev/null; then
    echo "已存在，跳过"
else
    echo "$LINE" >> "$HOME/.bashrc"
    echo "已追加"
fi

cat <<'EOF'

================ 完成 ================
后续手动两步（脚本管不到）:

1) Windows PowerShell 里重新挂载设备（让 udev 规则生效）:
     usbipd detach --busid 3-2
     usbipd attach --wsl --busid 3-2

2) 重启 WSL 让 plugdev 组生效:
     （Windows）wsl --shutdown  然后重开终端

验证（注意：不加 sudo）:
     cd ~/fpga_contest/hw/board
     openFPGALoader -b tangnano20k blink_led.fs
EOF
