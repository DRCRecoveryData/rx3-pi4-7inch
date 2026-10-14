#!/bin/bash
# setup-rx3-auto.sh — automatic XDJ-RX3 install on Raspberry Pi 4 + 7" DSI + DDJ-FLX4
# Based on mutlisensor/Rx3-flx4 (main branch)
# Chains all 6 manual steps into one command
#
# Run as normal user (NOT root):
#   bash setup-rx3-auto.sh 2>&1 | tee ~/rx3-install.log
set -euo pipefail

W="$HOME/Rx3-flx4"
H="$W/rx3-handoff"
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
  *"Raspberry Pi 5"*) warn "Pi 5 — upstream target; Pi 4 adaptations may not apply" ;;
  *) warn "Unknown model" ;;
esac

say "Requesting sudo"
sudo -v || die "sudo failed"

# --- 1. Packages --------------------------------------------------------------
say "Installing packages (step 1 of 6)"
sudo apt update
sudo apt install -y \
  git build-essential gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
  libfreetype6-dev pkg-config fonts-dejavu-core \
  fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
  python3 python3-pil python3-cryptography \
  rsync p7zip-full unzip curl evtest file

# --- 2. DSI overlay + cmdline (Pi 4 adaptation) -------------------------------
say "Applying Pi 4 display + USB adaptations"
CONFIG=/boot/firmware/config.txt
[ -f "$CONFIG" ] || CONFIG=/boot/config.txt
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt

if ! grep -q "vc4-kms-dsi-7inch" "$CONFIG"; then
  sudo cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
  echo "dtoverlay=vc4-kms-dsi-7inch" | sudo tee -a "$CONFIG" >/dev/null
  echo "  DSI overlay added"
else
  echo "  DSI overlay already present"
fi

if ! grep -q "usb-storage.quirks=174c:2362:u" "$CMDLINE"; then
  sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
  sudo sed -i 's|$| usb-storage.quirks=174c:2362:u vt.global_cursor_default=0 consoleblank=0|' "$CMDLINE"
  echo "  USB quirks added"
else
  echo "  USB quirks already present"
fi

# --- 3. Clone ------------------------------------------------------------------
say "Cloning mutlisensor/Rx3-flx4"
if [ -d "$W/.git" ]; then
  cd "$W" && git fetch origin
else
  git clone https://github.com/mutlisensor/Rx3-flx4.git "$W"
  cd "$W"
fi
git checkout main
git pull origin main || warn "pull failed (offline?)"
echo "  commit: $(git rev-parse --short HEAD)"

cd "$H"
chmod +x *.sh

# --- 4. Doctor check -----------------------------------------------------------
say "Running doctor check (step 3 of 6)"
./install.sh doctor || warn "doctor reported issues — continuing anyway"

# --- 5. Pi 4 adaptation: rx3-start.sh -----------------------------------------
say "Adapting rx3-start.sh for Pi 4"
if [ -f "$H/rx3-start.sh" ]; then
  python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/rx3-start.sh"
s = p.read_text()
changed = []
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
if old in s:
    s = s.replace(old, new, 1); changed.append("USB power-cycle disabled")
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" not in s and anchor in s:
    s = s.replace(anchor, add, 1); changed.append("fb0 unblank")
p.write_text(s)
print(f"  changes: {', '.join(changed) if changed else 'none needed'}")
PYEOF
fi

# --- 6. Recover firmware -------------------------------------------------------
say "Recovering firmware (step 2 of 6) — this downloads ~110 MB"
if [ -d "$H/extracted/runtime-files" ] && [ -f "$H/runtime-symlinks.json" ]; then
  echo "  firmware already extracted"
else
  cd "$H"
  python3 recover-firmware.py || die "recover-firmware.py failed"
  python3 extract_cramfs.py | tee /tmp/extract.log
  grep -q "Extraction complete." /tmp/extract.log || die "extraction incomplete — run extract_cramfs.py again"
  echo "  firmware extracted"
fi

# --- 7. Build chroot -----------------------------------------------------------
say "Building chroot (step 4 of 6) — expect ~6.5 GB, ~1 minute"
if [ -f "$HOME/rx3-rootfs/root/pdj/rbp-pi" ]; then
  echo "  chroot already built"
else
  cd "$H"
  ./build-rootfs.sh || die "build-rootfs.sh failed"
fi

# --- 8. Install host side ------------------------------------------------------
say "Installing host side (step 5 of 6)"
cd "$H"
./install.sh || die "install.sh failed"

# --- 9. Enable service ---------------------------------------------------------
say "Enabling service (step 6 of 6)"
sudo systemctl enable rx3
sudo systemctl restart rx3

# --- 10. Verify ----------------------------------------------------------------
say "Verifying"
sleep 5
systemctl is-active --quiet rx3 && echo "  rx3: active" || echo "  rx3: NOT active"
[ -f "$HOME/rx3-rootfs/dev/rx3-ctl" ] && cat "$HOME/rx3-rootfs/dev/rx3-ctl" | sed 's/^/  audio: /' || true

if [ "$AUTO_REBOOT" = "1" ]; then
  say "Rebooting in $REBOOT_DELAY seconds (Ctrl+C to cancel)"
  sleep "$REBOOT_DELAY"
  sudo reboot
else
  say "Done. Reboot when ready:  sudo reboot"
fi