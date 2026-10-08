#!/bin/bash
# rx3-pi4-install.sh — 7" DSI variant with all patches
#
# Included patches:
#   - Smart Fader (ch6 note 0x01) -> SOURCE
#   - Smart CFX   (ch6 note 0x00) -> BROWSE
#   - Master Cue  (ch6 note 0x63)
#   - Headphone CUE LED toggle (ch0/1 note 0x54)
#   - FX ON/OFF LED toggle (ch4 note 0x47)
#   - Pad mode LEDs (HOTCUE/PADFX1/BEATJUMP/SAMPLER)
#   - Hot cue pad A-H LED (solid on press, off on SHIFT+press)
#   - VU meters (3.3 Hz, fader-scaled, /tmp/rx3-leds from shim)
#
# Run as normal user (NOT root):
#   AUTO_REBOOT=0 bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

REPO="https://github.com/mutlisensor/Rx3-flx4.git"
W="$HOME/Rx3-flx4"; H="$W/rx3-handoff"; R="$HOME/rx3-rootfs"
ROT=0
USB_QUIRK="usb-storage.quirks=174c:2362:u"
CMDLINE_ADD="$USB_QUIRK vt.global_cursor_default=0 consoleblank=0"
AUTO_REBOOT="${AUTO_REBOOT:-1}"; REBOOT_DELAY=10

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" >/dev/null 2>&1 && pwd)"
ZIP="$SCRIPT_DIR/Rx3-flx4.zip"; [ -f "$ZIP" ] || ZIP="$SCRIPT_DIR/rx3-flx4.zip"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root."

say "Pi 4 RX3 installer (7\" DSI, all patches)"
echo "    Host: $(uname -srm)"
echo "    fb:   $(cat /sys/class/graphics/fb0/name 2>/dev/null) $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
echo "    Zip:  $ZIP $([ -f "$ZIP" ] && echo '(will use)' || echo '(absent — will clone)')"

say "Requesting sudo"
sudo -v || die "sudo failed"

# --- 1. cmdline -------------------------------------------------------------
say "Patching cmdline.txt"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
if ! grep -q "$USB_QUIRK" "$CMDLINE"; then
    sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
    sudo sed -i "s|\$| $CMDLINE_ADD|" "$CMDLINE"
    echo "    added"
else echo "    already present"; fi

# --- 2. packages ------------------------------------------------------------
say "Installing packages"
sudo apt update
sudo apt install -y \
    git build-essential gcc gcc-arm-linux-gnueabi \
    libfreetype6-dev pkg-config fonts-dejavu-core \
    fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
    python3 python3-pil python3-cryptography rsync p7zip-full \
    evtest curl unzip

# --- 3. source tree ---------------------------------------------------------
say "Preparing source tree at $W"
if [ -d "$W/rx3-handoff" ]; then say "Existing tree found"
elif [ -f "$ZIP" ]; then
    rm -rf "$W"; unzip -q "$ZIP" -d "$HOME"
    [ -d "$W/rx3-handoff" ] || die "Zip missing Rx3-flx4/rx3-handoff"
    say "Unzipped"
else
    git clone "$REPO" "$W"
fi
cd "$H"; chmod +x *.sh 2>/dev/null || true

# --- 4. patch rx3-start.sh --------------------------------------------------
say "Patching rx3-start.sh"
python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/rx3-start.sh"
s = p.read_text()
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
if old in s: s = s.replace(old, new, 1); print("    A) disabled")
old = "for wait in $(seq 1 30); do"; new = "for wait in $(seq 1 1); do"
if old in s: s = s.replace(old, new, 1); print("    B) shortened")
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" not in s and anchor in s: s = s.replace(anchor, add, 1); print("    C) added")
p.write_text(s)
PYEOF

# --- 4b. patch controller-bridge.py (all controller customisations) ---------
say "Patching controller-bridge.py"
python3 - <<'PYEOF'
from pathlib import Path
import sys
p = Path.home() / "Rx3-flx4/rx3-handoff/controller-bridge.py"
if not p.exists(): print("    MISS"); sys.exit(0)
s = p.read_text()
applied = []

# 1. K dict keys
if "mastercue=0x4407" not in s and "usb1=0x209)" in s:
    s = s.replace("usb1=0x209)", "usb1=0x209, mastercue=0x4407)", 1); applied.append("mastercue")
if "source=0x201" not in s and "source=0x0201" not in s and "browse=0x202," in s:
    s = s.replace("browse=0x202,", "browse=0x202, source=0x201,", 1); applied.append("source")

# 2. Smart Fader / Smart CFX / Master Cue (ch6)
if "# Smart Fader (ch6" not in s:
    anchor = "    elif ch == 6:\n        if ctl_id == 'xdjr1':\n            if n in (0x54, 0x55):"
    repl = ("    elif ch == 6:\n"
            "        if n == 0x01:\n"
            "            if down:\n"
            "                press(K['source'], 0, True); time.sleep(0.02); press(K['source'], 0, False)\n"
            "            return\n"
            "        if n == 0x00:\n"
            "            if down:\n"
            "                press(K['browse'], 0, True); time.sleep(0.02); press(K['browse'], 0, False)\n"
            "            return\n"
            "        if n == 0x63:\n"
            "            press(K['mastercue'], 0, down); return\n"
            "        if ctl_id == 'xdjr1':\n"
            "            if n in (0x54, 0x55):")
    if s.count(anchor) == 1:
        s = s.replace(anchor, repl, 1); applied.append("Smart FX")

# 3. PAD LED helpers
if "# ---- PAD LED simple" not in s:
    pad_anchor = "PAD = [0x4117 + i for i in range(8)]\n"
    pad_helpers = pad_anchor + '''
# ---- PAD LED simple ----
pad_cue = {1: {i: False for i in range(8)}, 2: {i: False for i in range(8)}}
def _pad_led_ch(deck): return 0x97 if deck == 1 else 0x99
def pad_led_set(deck, i, on):
    pad_cue[deck][i] = on
    led(_pad_led_ch(deck), i, on)
'''
    if pad_anchor in s:
        s = s.replace(pad_anchor, pad_helpers, 1); applied.append("pad helpers")

# 4. Pad press handler (LED on set, off on SHIFT)
old_pad = """    elif ch in (7, 9):                      # performance pads, deck 1 / deck 2
        deck = 1 if ch == 7 else 2
        if n < 0x08 or 0x20 <= n < 0x28 or 0x60 <= n < 0x68:
            press(PAD[n & 7], deck, down); return
"""
new_pad = """    elif ch in (7, 9):
        deck = 1 if ch == 7 else 2
        if n < 0x08 or 0x20 <= n < 0x28 or 0x60 <= n < 0x68:
            i = n & 7
            if down and pad_mode[deck] == 0x1B:
                if n < 0x08:
                    if not pad_cue[deck][i]: pad_led_set(deck, i, True)
                elif 0x20 <= n < 0x28:
                    pad_led_set(deck, i, False)
            press(PAD[n & 7], deck, down); return
"""
if old_pad in s:
    s = s.replace(old_pad, new_pad, 1); applied.append("pad press")

# 5. SHIFT+pad handler
old_shift = """    elif ch in (8, 10):                     # shift + pads
        deck = 1 if ch == 8 else 2
        if n < 0x08: press(K['shift'], deck, True); press(PAD[n & 7], deck, down); press(K['shift'], deck, False); return
"""
new_shift = """    elif ch in (8, 10):
        deck = 1 if ch == 8 else 2
        if n < 0x08:
            i = n & 7
            if down:
                if pad_mode[deck] == 0x1B: pad_led_set(deck, i, False)
                press(K['shift'], deck, True); press(PAD[n & 7], deck, True)
            else:
                press(PAD[n & 7], deck, False); press(K['shift'], deck, False)
            return
"""
if old_shift in s:
    s = s.replace(old_shift, new_shift, 1); applied.append("shift+pad")

# 6. hpcue LED toggle
if "# FLX4 hpcue LED fix" not in s:
    old = "        if name == 'hpcue': press(K['hpcue'], deck, down); return\n"
    new = ("        if name == 'hpcue':\n"
           "            press(K['hpcue'], deck, down)\n"
           "            if down:\n"
           "                hp_cue[deck] = not hp_cue[deck]\n"
           "                led(status, 0x54, hp_cue[deck])\n"
           "            return\n")
    if old in s:
        s = s.replace(old, new, 1); applied.append("hpcue LED")
        dead = "    if ch in (0, 1) and n == 0x54 and down: hp_cue[ch + 1] = not hp_cue[ch + 1]; led(status, 0x54, hp_cue[ch + 1])\n"
        if dead in s: s = s.replace(dead, "", 1)

# 7. FX ON/OFF LED
if "# FLX4 FX ON/OFF LED" not in s:
    old = "    if ch in (4, 5):                        # BEAT FX section\n        global beatfx_index\n"
    new = ("    if ch in (4, 5):                        # BEAT FX section\n"
           "        global beatfx_index\n"
           "        if ch == 4 and n == 0x47:\n"
           "            if down:\n"
           "                beatfx_on[0] = not beatfx_on[0]\n"
           "                led(0x94, 0x47, beatfx_on[0])\n"
           "            press(K['fxonoff'], 0, down); return\n")
    if old in s:
        s = s.replace(old, new, 1); applied.append("FX LED")

# 8. VU meters
if "FirmwareLeds" not in s:
    if "import struct" not in s:
        for m in ("import os", "import sys", "import time"):
            if m in s: s = s.replace(m, "import struct\n" + m, 1); break
    vu_anchor = "        except OSError as e: print('controller-bridge: MIDI out failed:', e, file=sys.stderr, flush=True); os._exit(3)\n"
    vu_block = vu_anchor + '''
import struct as _struct
class FirmwareLeds:
    PATH = ROOT + '/tmp/rx3-leds'
    def __init__(self): self.data = None
    def read(self):
        try:
            with open(self.PATH, 'rb') as f: d = f.read(16 + 64*16 + 8)
        except OSError: self.data = None; return False
        if len(d) < 16 + 64*16 + 8 or d[:4] != b'RXL1': self.data = None; return False
        self.data = d; return True
    def level_db(self, deck):
        o = 16 + 64*16 + 4 * (deck - 1)
        return _struct.unpack_from('<i', self.data, o)[0] if len(self.data) >= o + 4 else None
firmware_leds = FirmwareLeds()
def meter_step(db):
    if db is None or db < -24: return 0
    if db > 14: return 11
    return (1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6,7,7,7,8,8,8,9,9,9,10,10,10)[db + 24]
led_sent = {}
fader_pos = {1: 127, 2: 127}
def led_loop():
    while True:
        try:
            if firmware_leds.read():
                for d in (1, 2):
                    db = firmware_leds.level_db(d)
                    vu = 0 if (db is None or db == -2147483648) else round(meter_step(db) * 127 / 11)
                    vu = (vu * fader_pos[d]) // 127
                    if led_sent.get(('vu', d)) != vu:
                        led_sent[('vu', d)] = vu
                        midi_write(bytes([0xB0 + d - 1, 0x02, vu]))
        except Exception: pass
        time.sleep(0.30)
threading.Thread(target=led_loop, daemon=True).start()
'''
    if vu_anchor in s:
        s = s.replace(vu_anchor, vu_block, 1); applied.append("VU")

# 9. fader capture
if "fader_pos[ch+1] = v" not in s and "fader_pos" in s:
    cc_anchor = "        if c in DECK_CC: analog(K[DECK_CC[c]], deck, v / 127.0); return"
    cc_new = "        if c in DECK_CC:\n            if c == 0x13: fader_pos[ch+1] = v\n            analog(K[DECK_CC[c]], deck, v / 127.0); return"
    if cc_anchor in s:
        s = s.replace(cc_anchor, cc_new, 1); applied.append("fader capture")

# 10. PAD_MODES before DECK_NOTES
if "# PAD MODES: check first" not in s:
    old_pad2 = """    if ch in (0, 1) and n in PAD_MODES:
        deck = ch + 1
        if not down: return
        pad_mode[deck] = n; show_pad_mode(deck)
        if n == 0x1B:
            if rx3_mode[deck] == 'hotcue': return
            rx3_mode[deck] = 'hotcue'
        elif n == 0x20:
            if rx3_mode[deck] == 'beatjump': return
            rx3_mode[deck] = 'beatjump'
        elif n == 0x6D:
            if rx3_mode[deck] == 'beatloop': return
            rx3_mode[deck] = 'beatloop'
        else: return
"""
    if old_pad2 in s: s = s.replace(old_pad2, "", 1)
    anchor2 = "    if ch in (0, 1):\n        deck = ch + 1\n"
    new_block = anchor2 + """        # PAD MODES: check first
        if n in PAD_MODES:
            if not down: return
            pad_mode[deck] = n; show_pad_mode(deck)
            if n == 0x1B:
                if rx3_mode[deck] == 'hotcue': return
                rx3_mode[deck] = 'hotcue'
            elif n == 0x20:
                if rx3_mode[deck] == 'beatjump': return
                rx3_mode[deck] = 'beatjump'
            elif n == 0x6D:
                if rx3_mode[deck] == 'beatloop': return
                rx3_mode[deck] = 'beatloop'
            else: return

"""
    if anchor2 in s and "PAD MODES: check first" not in s:
        s = s.replace(anchor2, new_block, 1); applied.append("pad modes order")

if applied:
    p.write_text(s)
    print(f"    applied: {', '.join(applied)}")
else:
    print("    already patched")
PYEOF

# --- 4c. patch control-shim.c (VU level publishing) -------------------------
say "Patching control-shim.c"
python3 - <<'PYEOF'
from pathlib import Path
import sys
p = Path.home() / "Rx3-flx4/rx3-handoff/control-shim.c"
if not p.exists(): print("    MISS"); sys.exit(0)
s = p.read_text()
if "led_thread" in s: print("    already patched"); sys.exit(0)
anchor = "__attribute__((constructor))static void start_control(void){"
addition = r"""static void put_levels(unsigned char *o){
 long (*level)(void*,int)=(void*)0x50170;
 void *eng = *(void *volatile *)0x011492d8;
 if(!eng){for(int k=0;k<8;k++)o[k]=0;return;}
 for(int ch=0;ch<2;ch++){
  long v = level(eng, ch);
  for(int k=0;k<4;k++) o[ch*4+k] = (unsigned long)v >> (8*k);
 }
}
static void *led_thread(void *unused){
 (void)unused;
 sleep(10);
 while(!*(void *volatile *)0x011492d8) sleep(1);
 const char m[]="RX3 LEDs: publishing levels to /tmp/rx3-leds\n";write(2,m,sizeof(m)-1);
 int fd=open("/tmp/rx3-leds",O_WRONLY|O_CREAT|O_TRUNC,0644);
 if(fd<0){const char e[]="RX3 LEDs: cannot open /tmp/rx3-leds\n";write(2,e,sizeof(e)-1);return 0;}
 static unsigned char buf[16+64*2*8+8];
 buf[0]='R';buf[1]='X';buf[2]='L';buf[3]='1';
 buf[8]=64;buf[9]=0;
 unsigned seq=0;
 for(;;){
  usleep(300000);
  seq++;
  buf[4]=seq;buf[5]=seq>>8;buf[6]=seq>>16;buf[7]=seq>>24;
  memset(buf+16,0,64*2*8);
  put_levels(buf+16+64*2*8);
  pwrite(fd,buf,sizeof(buf),0);
 }
 return 0;
}
"""
if anchor not in s: print("    MISS anchor"); sys.exit(0)
s = s.replace(anchor, addition + anchor, 1)
old = " unsigned long thread;pthread_create(&thread,0,control_thread,0);\n}"
new = " unsigned long thread;pthread_create(&thread,0,control_thread,0);\n unsigned long lt;pthread_create(&lt,0,led_thread,0);\n}"
if old in s:
    s = s.replace(old, new, 1)
    p.write_text(s); print("    applied")
PYEOF

# --- 5. rx3.conf ------------------------------------------------------------
say "Writing rx3.conf"
cat > "$H/rx3.conf" <<EOF
RX3_FB=/dev/fb0
RX3_ROTATE=$ROT
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
EOF

# --- 6. touch driver --------------------------------------------------------
say "Touch driver"
if lsmod | grep -q '^raspberrypi_ts'; then
    printf 'blacklist edt_ft5x06\nblacklist edt-ft5x06\n' | sudo tee /etc/modprobe.d/blacklist-edt-ft5x06.conf >/dev/null
    sudo update-initramfs -u || true
else
    sudo rm -f /etc/modprobe.d/blacklist-edt-ft5x06.conf
fi

# --- 7. firmware ------------------------------------------------------------
if [ -f "$H/runtime-symlinks.json" ] && [ -d "$H/extracted/runtime-files" ]; then
    say "Firmware already extracted"
else
    say "Recovering firmware"
    python3 "$H/recover-firmware.py" || die "recover failed"
    python3 "$H/extract_cramfs.py" | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract incomplete"
fi

# --- 8. chroot --------------------------------------------------------------
if [ -f "$R/etc/rx3-ctl" ] && [ -d "$R/root/pdj" ]; then
    say "Chroot exists"
else
    say "Building chroot"
    for m in $(mount | awk -v r="$R" 'index($3,r)==1{print $3}' | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
    "$H/build-rootfs.sh" | tee /tmp/build.log
    grep -q '^== done' /tmp/build.log || die "build-rootfs failed"
fi

# --- 8b. rebuild fbshim.so --------------------------------------------------
say "Rebuilding fbshim.so"
if grep -q "led_thread" "$H/control-shim.c"; then
    ( cd "$H" && arm-linux-gnueabi-gcc -shared -fPIC -O2 -fomit-frame-pointer -fno-builtin -nostdlib \
        -o "$R/lib/fbshim.so" fbshim.c control-shim.c ) || die "gcc failed"
    arm-linux-gnueabi-nm "$R/lib/fbshim.so" 2>/dev/null | grep -q "led_thread" || die "no led_thread"
    echo "    ok"
fi

# --- 9-11. install + enable + doctor ----------------------------------------
say "Running install.sh"
"$H/install.sh"
sudo systemctl daemon-reload
sudo systemctl enable rx3.service

say "Final doctor"
"$H/install.sh" doctor || true

echo
echo "============================================================"
echo "  INSTALL COMPLETE"
echo "  Smart Fader -> SOURCE, Smart CFX -> BROWSE"
echo "  Master Cue, hpcue LED toggle, FX LED toggle"
echo "  Pad mode LEDs, hot cue pad A-H LED"
echo "  VU meters (3.3 Hz, fader-scaled)"
echo "============================================================"
echo

if [ "$AUTO_REBOOT" = "1" ]; then
    echo "Rebooting in $REBOOT_DELAY s — Ctrl+C to cancel."
    for i in $(seq "$REBOOT_DELAY" -1 1); do printf "\r    %2d s ... " "$i"; sleep 1; done
    printf "\r    rebooting now        \n"
    sudo systemctl reboot
else
    echo "Skipping reboot. Run: sudo reboot"
fi
