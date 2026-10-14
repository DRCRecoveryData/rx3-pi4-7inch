#!/bin/bash
# setup-mutlisensor.sh
# Prepares a Raspberry Pi 4 for the mutlisensor/Rx3-flx4 project.
#
# This script does NOT install the full RX3 firmware. It:
#   1. Installs dependencies
#   2. Adds the official 7" DSI overlay + USB quirks
#   3. Clones the repo and checks out 7inch
#   4. Applies Pi 4 adaptations to rx3-start.sh
#   5. Stops and tells you to follow their INSTALL.md
#
# Assumes the Beat FX "1 & 2" fix is already merged upstream.
# If you hit a bug where the "1 & 2" selector only applies FX to one
# deck, that PR hasn't landed yet — apply the debounce manually.
#
# Run as normal user (NOT root):
#   bash setup-mutlisensor.sh 2>&1 | tee ~/setup-mutlisensor.log
set -euo pipefail

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root."
[ -f /etc/rpi-issue ] || warn "This doesn't look like Raspberry Pi OS."
[ "$(uname -m)" = "aarch64" ] || warn "Expected aarch64 (64-bit OS)."

say "Checking Raspberry Pi model"
MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
echo "  $MODEL"
case "$MODEL" in
  *"Raspberry Pi 4"*) echo "  OK — Pi 4 detected" ;;
  *"Raspberry Pi 5"*) warn "Pi 5 — this script targets Pi 4; upstream expects Pi 5" ;;
  *) warn "Unknown model — proceeding anyway" ;;
esac

say "Requesting sudo"
sudo -v || die "sudo failed"

# --- 1. system update --------------------------------------------------------
say "Updating package index"
sudo apt update

say "Installing dependencies"
sudo apt install -y \
  git build-essential gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi \
  libfreetype6-dev pkg-config fonts-dejavu-core \
  fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
  python3 python3-pil python3-cryptography python3-numpy \
  rsync p7zip-full unzip curl evtest file

# --- 2. DSI overlay for official 7" panel ------------------------------------
say "Configuring official 7\" DSI overlay"
CONFIG=/boot/firmware/config.txt
[ -f "$CONFIG" ] || CONFIG=/boot/config.txt
[ -f "$CONFIG" ] || die "config.txt not found"
if grep -q "vc4-kms-dsi-7inch" "$CONFIG"; then
  echo "  already present"
else
  sudo cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
  {
    echo ""
    echo "# Added by setup-mutlisensor.sh — official 7\" DSI panel"
    echo "dtoverlay=vc4-kms-dsi-7inch"
  } | sudo tee -a "$CONFIG" >/dev/null
  echo "  overlay added (reboot will apply)"
fi

# --- 3. cmdline USB quirk ----------------------------------------------------
say "Patching cmdline.txt"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
[ -f "$CMDLINE" ] || die "cmdline.txt not found"
if ! grep -q "usb-storage.quirks=174c:2362:u" "$CMDLINE"; then
  sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
  sudo sed -i 's|$| usb-storage.quirks=174c:2362:u vt.global_cursor_default=0 consoleblank=0|' "$CMDLINE"
  echo "  quirks added"
else
  echo "  already present"
fi

# --- 4. clone the repo -------------------------------------------------------
say "Cloning mutlisensor/Rx3-flx4"
W="$HOME/Rx3-flx4"
if [ -d "$W/.git" ]; then
  echo "  already cloned at $W"
  cd "$W"
  git fetch origin
else
  git clone https://github.com/mutlisensor/Rx3-flx4.git "$W"
  cd "$W"
fi

say "Checking out the 7inch branch"
git checkout 7inch
git pull origin 7inch || warn "pull failed (offline?)"
echo "  branch: $(git branch --show-current)"
echo "  commit: $(git rev-parse --short HEAD)"

# --- 5. Pi 4 adaptation: rx3-start.sh ----------------------------------------
say "Adapting rx3-start.sh for Pi 4"
if [ -f rx3-handoff/rx3-start.sh ]; then
  python3 - <<'PYEOF'
from pathlib import Path
p = Path('rx3-handoff/rx3-start.sh')
s = p.read_text()
changed = []

# Disable Pi 5 USB VBUS power-cycle (RP1 chip doesn't exist on Pi 4)
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
if old in s:
    s = s.replace(old, new, 1); changed.append("USB power-cycle disabled")

# Unblank framebuffer at startup
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" not in s and anchor in s:
    s = s.replace(anchor, add, 1); changed.append("fb0 unblank")

p.write_text(s)
print(f"  changes: {', '.join(changed) if changed else 'none needed'}")
PYEOF
else
  warn "rx3-start.sh not found — inspect repo layout first"
fi

# --- 6. Report ---------------------------------------------------------------
say "Setup phase complete"
echo
echo "Files in rx3-handoff/:"
ls -1 rx3-handoff/ 2>/dev/null | sed 's/^/  /'
echo
echo "Next steps (MANUAL — read their docs):"
echo
echo "  1. sudo reboot          # apply DSI overlay + cmdline changes"
echo "  2. cd $W"
echo "  3. cat README.md"
echo "  4. cat INSTALL.md 2>/dev/null || ls -la"
echo "  5. Follow their instructions step by step."
echo
echo "Notes:"
echo "  - They do NOT ship an installer. Setup is manual."
echo "  - You must supply the XDJ-RX3 v1.19 firmware yourself."
echo "  - Their docs target Pi 5 + Touch Display 2; you're on Pi 4 + DSI."
echo "  - If FLX4 '1 & 2' Beat FX applies to only one deck, the PR"
echo "    hasn't merged yet — apply the 40 ms debounce manually."
echo
echo "Log saved to: $HOME/setup-mutlisensor.log"
