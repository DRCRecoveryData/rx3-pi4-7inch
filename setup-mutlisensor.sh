#!/bin/bash
# setup-rx3-auto.sh — automatic XDJ-RX3 install on Raspberry Pi 4
#                    + ORIGINAL official 7" DSI panel (800×480)
#                    + DDJ-FLX4
#
# Based on mutlisensor/Rx3-flx4 (main branch) — INSTALL.md steps 1–6,
# chained into one command with Pi 4 and original-DSI adaptations.
#
# Run as normal user (NOT root):
#   bash setup-rx3-auto.sh 2>&1 | tee ~/rx3-install.log
#
# Options:
#   AUTO_REBOOT=0  skip the reboot at the end
set -euo pipefail

W="$HOME/Rx3-flx4"
H="$W/rx3-handoff"
R="$HOME/rx3-rootfs"
AUTO_REBOOT="${AUTO_REBOOT:-1}"
REBOOT_DELAY=10

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root."
[ -f /etc/rpi-issue ] || warn "Not Raspberry Pi OS"
[ "$(uname -m)" = "aarch64" ] || die "Need 64-bit OS"

MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
echo "  Model: $MODEL"
case "$MODEL" in
  *"Raspberry Pi 4"*) echo "  Pi 4 detected" ;;
  *"Raspberry Pi 5"*) warn "Pi 5 — upstream target; Pi 4 adaptations may conflict" ;;
  *) warn "Unknown model" ;;
esac

say "Requesting sudo"
sudo -v || die "sudo failed"

# =============================================================================
# STEP 1 — Packages
# =============================================================================
say "STEP 1/6 — Installing packages"
sudo apt update
sudo apt install -y \
  git build-essential gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
  libfreetype6-dev pkg-config fonts-dejavu-core \
  fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
  python3 python3-pil python3-cryptography \
  rsync p7zip-full unzip curl evtest file

# =============================================================================
# STEP 2 — Pi 4 + ORIGINAL 7" DSI adaptations
# =============================================================================
say "STEP 2/6 — Applying Pi 4 + original-DSI adaptations"

CONFIG=/boot/firmware/config.txt
[ -f "$CONFIG" ] || CONFIG=/boot/config.txt
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
[ -f "$CONFIG" ] || die "config.txt not found"
[ -f "$CMDLINE" ] || die "cmdline.txt not found"

# --- DSI overlay: ORIGINAL 7" panel (800×480), NOT Touch Display 2 -----------
# Remove any Touch Display 2 overlay that a previous run might have added
if grep -q "vc4-kms-dsi-ili9881-7inch" "$CONFIG"; then
  echo "  Removing Touch Display 2 overlay (wrong panel for this hardware)"
  sudo sed -i '/vc4-kms-dsi-ili9881-7inch/d' "$CONFIG"
fi

if ! grep -q "vc4-kms-dsi-7inch" "$CONFIG"; then
  sudo cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
  {
    echo ""
    echo "# Added by setup-rx3-auto.sh — ORIGINAL official 7\" DSI panel"
    echo "dtoverlay=vc4-kms-dsi-7inch"
  } | sudo tee -a "$CONFIG" >/dev/null
  echo "  DSI overlay: vc4-kms-dsi-7inch (original panel) added"
else
  echo "  DSI overlay: vc4-kms-dsi-7inch already present"
fi

# --- USB quirks + console -----------------------------------------------------
if ! grep -q "usb-storage.quirks=174c:2362:u" "$CMDLINE"; then
  sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
  sudo sed -i 's|$| usb-storage.quirks=174c:2362:u vt.global_cursor_default=0 consoleblank=0|' "$CMDLINE"
  echo "  USB quirks + console settings added"
else
  echo "  USB quirks already present"
fi

# --- Touch driver: blacklist edt_ft5x06 (conflicts with DSI panel) -----------
if [ ! -f /etc/modprobe.d/blacklist-edt-ft5x06.conf ]; then
  echo "blacklist edt_ft5x06" | sudo tee /etc/modprobe.d/blacklist-edt-ft5x06.conf >/dev/null
  sudo update-initramfs -u || true
  echo "  Touch driver edt_ft5x06 blacklisted"
else
  echo "  Touch driver blacklist already present"
fi

# =============================================================================
# STEP 3 — Clone source tree
# =============================================================================
say "STEP 3/6 — Cloning mutlisensor/Rx3-flx4"
if [ -d "$W/.git" ]; then
  echo "  Repo already present at $W"
  cd "$W"
  git fetch origin
else
  git clone https://github.com/mutlisensor/Rx3-flx4.git "$W"
  cd "$W"
fi
git checkout main
git pull origin main || warn "git pull failed (offline?) — continuing with local copy"
echo "  Branch: $(git branch --show-current)"
echo "  Commit: $(git rev-parse --short HEAD)"

cd "$H"
chmod +x *.sh

# =============================================================================
# STEP 4 — Pi 4 adaptation of rx3-start.sh
# =============================================================================
say "Adapting rx3-start.sh for Pi 4"
if [ -f "$H/rx3-start.sh" ]; then
  python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/rx3-start.sh"
s = p.read_text()
changed = []

# 1. Disable Pi 5 USB VBUS power-cycle (RP1 chip doesn't exist on Pi 4)
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("USB power-cycle disabled")

# 2. Unblank framebuffer at startup
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" not in s and anchor in s:
    s = s.replace(anchor, add, 1)
    changed.append("fb0 unblank")

p.write_text(s)
print(f"  Changes: {', '.join(changed) if changed else 'none needed (already adapted)'}")
PYEOF
else
  warn "rx3-start.sh not found — check repo layout"
fi

# =============================================================================
# STEP 5 — Firmware recovery + chroot build (INSTALL.md step 2 + step 4)
# =============================================================================
say "STEP 5/6 — Firmware + chroot"

# --- Doctor check -------------------------------------------------------------
say "  Doctor check"
cd "$H"
./install.sh doctor || warn "  doctor reported issues — continuing"

# --- Firmware recovery --------------------------------------------------------
if [ -d "$H/extracted/runtime-files" ] && [ -f "$H/runtime-symlinks.json" ]; then
  echo "  Firmware already extracted"
else
  echo "  Recovering firmware (~110 MB download from Pioneer)"
  cd "$H"
  python3 recover-firmware.py || die "recover-firmware.py failed"
  python3 extract_cramfs.py | tee /tmp/extract.log
  grep -q "Extraction complete." /tmp/extract.log || die "extraction incomplete"
  echo "  Firmware extracted"
fi

# --- Chroot build -------------------------------------------------------------
if [ -f "$R/root/pdj/rbp-pi" ]; then
  echo "  Chroot already built at $R"
else
  echo "  Building ARM32 chroot (~6.5 GB, takes ~1 minute)"
  cd "$H"
  ./build-rootfs.sh || die "build-rootfs.sh failed"
fi

# =============================================================================
# STEP 6 — Host install + service enable (INSTALL.md step 5 + step 6)
# =============================================================================
say "STEP 6/6 — Host install + service"

cd "$H"
./install.sh || die "install.sh failed"

sudo systemctl enable rx3
sudo systemctl restart rx3

# =============================================================================
# Verify
# =============================================================================
say "Verifying"
sleep 5

systemctl is-active --quiet rx3 && echo "  rx3.service: active" || echo "  rx3.service: NOT active"

if [ -f "$R/dev/rx3-ctl" ]; then
  cat "$R/dev/rx3-ctl" | sed 's/^/  audio card: /'
fi

if [ -f "$R/tmp/rx3-leds" ]; then
  echo "  /tmp/rx3-leds: present ($(stat -c%s "$R/tmp/rx3-leds") bytes)"
else
  echo "  /tmp/rx3-leds: not yet created (shim will create it once firmware runs)"
fi

# =============================================================================
# Reboot
# =============================================================================
if [ "$AUTO_REBOOT" = "1" ]; then
  say "Rebooting in $REBOOT_DELAY seconds (Ctrl+C to cancel)"
  sleep "$REBOOT_DELAY"
  sudo reboot
else
  say "Done. Reboot when ready:  sudo reboot"
fi