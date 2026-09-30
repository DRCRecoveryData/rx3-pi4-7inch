#!/bin/bash
# rx3-pi4-install.sh — 7" DSI (FocalTech FT5x06) variant
#
# Processes Rx3-flx4.zip if present next to this script; otherwise falls
# back to the upstream mutlisensor/Rx3-flx4 clone.
#
# Run as your normal user (NOT root):
#   git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
#   cd rx3-pi4-7inch
#   chmod +x rx3-pi4-install.sh
#   AUTO_REBOOT=0 bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

REPO="https://github.com/mutlisensor/Rx3-flx4.git"
W="$HOME/Rx3-flx4"
H="$W/rx3-handoff"
R="$HOME/rx3-rootfs"
ROT=0
USB_QUIRK="usb-storage.quirks=174c:2362:u"
CMDLINE_ADD="$USB_QUIRK vt.global_cursor_default=0 consoleblank=0"
AUTO_REBOOT="${AUTO_REBOOT:-1}"
REBOOT_DELAY=10

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" >/dev/null 2>&1 && pwd)"
ZIP="$SCRIPT_DIR/Rx3-flx4.zip"
[ -f "$ZIP" ] || ZIP="$SCRIPT_DIR/rx3-flx4.zip"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root — the installer calls sudo itself."

say "Pi 4 RX3 installer (7\" DSI variant)"
echo "    Host: $(uname -srm)"
echo "    User: $(id -un) (uid $(id -u))"
echo "    Home: $HOME"
echo "    fb:   $(cat /sys/class/graphics/fb0/name 2>/dev/null) $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
echo "    Zip:  $ZIP $([ -f "$ZIP" ] && echo '(will be used)' || echo '(absent — will clone GitHub)')"
echo "    Auto-reboot: $AUTO_REBOOT"

say "Requesting sudo"
sudo -v || die "sudo failed"

# --- 1. cmdline -------------------------------------------------------------
say "Patching /boot/firmware/cmdline.txt"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
[ -f "$CMDLINE" ] || die "cmdline.txt not found"
if ! grep -q "$USB_QUIRK" "$CMDLINE"; then
    sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
    sudo sed -i "s|\$| $CMDLINE_ADD|" "$CMDLINE"
    echo "    added: $CMDLINE_ADD"
else
    echo "    already present"
fi

# --- 2. packages ------------------------------------------------------------
say "Installing build dependencies"
sudo apt update
sudo apt install -y \
    git build-essential gcc gcc-arm-linux-gnueabi \
    libfreetype6-dev pkg-config fonts-dejavu-core \
    fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
    python3 python3-pil python3-cryptography rsync p7zip-full \
    evtest curl unzip

# --- 3. source tree ---------------------------------------------------------
say "Preparing source tree at $W"
if [ -d "$W/rx3-handoff" ]; then
    say "Existing tree found — leaving it in place"
elif [ -f "$ZIP" ]; then
    say "Unzipping $ZIP -> $HOME/"
    rm -rf "$W"
    unzip -q "$ZIP" -d "$HOME"
    [ -d "$W/rx3-handoff" ] || die "Zip did not contain Rx3-flx4/rx3-handoff"
    say "Unzipped OK"
else
    say "No local zip and no existing tree — cloning GitHub"
    git clone "$REPO" "$W"
fi

cd "$H"
chmod +x *.sh 2>/dev/null || true

# --- 4. patch rx3-start.sh --------------------------------------------------
say "Patching rx3-start.sh"
python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/rx3-start.sh"
s = p.read_text()
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
print("    A) " + ("already disabled" if new in s else "disabled" if old in s else "MISS"))
if old in s: s = s.replace(old, new, 1)
old = "for wait in $(seq 1 30); do"; new = "for wait in $(seq 1 1); do"
print("    B) " + ("already short" if new in s else "shortened" if old in s else "MISS"))
if old in s: s = s.replace(old, new, 1)
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" in s: print("    C) already present")
elif anchor in s: s = s.replace(anchor, add, 1); print("    C) added")
else: print("    C) MISS")
p.write_text(s)
PYEOF

# --- 5. rx3.conf ------------------------------------------------------------
say "Writing rx3.conf"
cat > "$H/rx3.conf" <<EOF
RX3_FB=/dev/fb0
RX3_ROTATE=$ROT
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
EOF
cat "$H/rx3.conf"

# --- 6. touch driver (7" FT5x06 safe) --------------------------------------
say "Checking touch driver"
if lsmod | grep -q '^raspberrypi_ts'; then
    say "raspberrypi-ts present — blacklisting edt_ft5x06"
    printf 'blacklist edt_ft5x06\nblacklist edt-ft5x06\n' | \
        sudo tee /etc/modprobe.d/blacklist-edt-ft5x06.conf >/dev/null
    sudo update-initramfs -u || true
else
    say "edt_ft5x06 is the active touch driver (7\" DSI) — NOT blacklisting"
    sudo rm -f /etc/modprobe.d/blacklist-edt-ft5x06.conf
fi

# --- 7. firmware ------------------------------------------------------------
if [ -f "$H/runtime-symlinks.json" ] && [ -d "$H/extracted/runtime-files" ]; then
    say "Firmware already extracted"
else
    say "Recovering firmware (~110 MB from Pioneer)"
    python3 "$H/recover-firmware.py" || die "recover-firmware.py failed"
    python3 "$H/extract_cramfs.py" | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py incomplete"
fi

# --- 8. chroot --------------------------------------------------------------
if [ -f "$R/etc/rx3-ctl" ] && [ -d "$R/root/pdj" ]; then
    say "Chroot already built ($(du -sh "$R" | cut -f1))"
else
    say "Building chroot"
    for m in $(mount | awk -v r="$R" 'index($3,r)==1{print $3}' | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
    "$H/build-rootfs.sh" | tee /tmp/build.log
    grep -q '^== done' /tmp/build.log || die "build-rootfs.sh failed"
fi

# --- 9. host install --------------------------------------------------------
say "Running upstream install.sh"
"$H/install.sh"

# --- 10. enable service -----------------------------------------------------
say "Enabling rx3.service"
sudo systemctl daemon-reload
sudo systemctl enable rx3.service
sudo systemctl is-enabled rx3.service

# --- 11. doctor -------------------------------------------------------------
say "Final doctor"
"$H/install.sh" doctor || true

echo
echo "============================================================"
echo "  INSTALL COMPLETE"
echo "============================================================"
echo "  Repo:      $W"
echo "  Chroot:    $R"
echo "  Presenter: $HOME/rx3-fb-present"
echo "  Touch:     $HOME/rx3-touch-bridge"
echo "  Config:    $H/rx3.conf"
echo "  Service:   rx3.service (enabled)"
echo

if [ "$AUTO_REBOOT" = "1" ]; then
    echo "Rebooting in $REBOOT_DELAY s — Ctrl+C to cancel."
    for i in $(seq "$REBOOT_DELAY" -1 1); do
        printf "\r    rebooting in %2d s ... " "$i"; sleep 1
    done
    printf "\r    rebooting now          \n"
    sudo systemctl reboot
else
    echo "Skipping reboot (AUTO_REBOOT=0). Run: sudo reboot"
fi
