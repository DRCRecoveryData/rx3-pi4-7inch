rx3-pi4-7inch

Run the Pioneer XDJ-RX3 rekordbox player on a Raspberry Pi 4 with a 7" DSI touch display and a DDJ-FLX4 controller.

This installer sets up everything: the RX3 firmware in a chroot, a display presenter for the 7" DSI panel, a controller bridge for the FLX4, and an offline USB update system.

---

What it does

Component Purpose
rbp-pi Pioneer's XDJ-RX3 firmware running in an ARM32 chroot
rx3-fb-present Copies firmware frames to /dev/fb0 (7" DSI, 800×480)
controller-bridge.py Translates DDJ-FLX4 MIDI into RX3 firmware commands and drives the controller's LEDs
control-shim.c LD_PRELOAD shim that hooks the firmware and publishes mixer levels
fbshim.c LD_PRELOAD shim that tracks audio writes and detects stalls
rx3.service systemd unit that starts everything at boot

---

Hardware requirements

Item Notes
Raspberry Pi 4 Any RAM size (1/2/4/8 GB). Pi 3, Pi 5 not supported.
Official 7" DSI touch panel 800×480. Other DSI panels may need config changes.
DDJ-FLX4 Tested with firmware as shipped. Other controllers need MIDI map changes.
USB-C power supply 5.1 V / 3 A minimum (official Pi 4 PSU recommended)
MicroSD card 16 GB or larger

---

Features

Verified working

· RX3 UI on 7" DSI — full firmware interface, touch enabled
· Audio through the FLX4 — 2-channel output to the controller's sound card
· USB media playback — mount removable drives via copy-on-write overlay
· Autostart on boot — systemd handles everything

Controller mappings (DDJ-FLX4)

All mappings verified on hardware:

FLX4 control Action
Smart Fader (ch6 note 0x01) Opens the firmware's Source screen
Smart CFX (ch6 note 0x00) Opens the firmware's Browse screen
Master Cue (ch6 note 0x63) Toggles the firmware's master cue
Headphone Cue deck 1/2 (ch0/1 note 0x54) Toggles cue + LED in sync
FX ON/OFF (ch4 note 0x47) Toggles the beat FX, LED mirrors state
Pad mode buttons HOTCUE / PADFX1 / BEATJUMP / SAMPLER — LED shows active mode
Hot cue pads A–H LED turns on when cue set, off on SHIFT+press
Shift + pad Clears the pad LED and the firmware cue

VU meters

The FLX4's deck VU meters show the firmware's channel levels, driven through MIDI CC 0x02:

· Levels come from DjEngineIF::getInputChLevelMono inside the firmware
· Published to /tmp/rx3-leds by control-shim.c (300 ms poll)
· Read by controller-bridge.py, scaled by the physical channel fader position
· Sent as 0xB0 0x02 <value> (deck 1) / 0xB1 0x02 <value> (deck 2)
· Polled at 3.3 Hz — slow enough that the FLX4's single MIDI endpoint survives continuous output while still reading input

Note: Earlier versions tried 33 Hz and 10 Hz polling. Both wedged the FLX4 within minutes. 3.3 Hz is the fastest rate that has proven stable on tested hardware.

Known limitations

· Pad LEDs blank while SHIFT is held — this is FLX4 firmware behavior, not fixable over MIDI.
· Pad F may blink by default — an FLX4 quirk in HOTCUE mode. The bridge does not interfere.

---

Installation

Quick start

```bash
git clone https://github.com/YOUR-USERNAME/rx3-pi4-7inch.git
cd rx3-pi4-7inch
chmod +x rx3-pi4-install.sh
AUTO_REBOOT=0 bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

The installer will:

1. Patch /boot/firmware/cmdline.txt with USB quirks
2. Install build dependencies
3. Clone or unzip the Rx3-flx4 source tree
4. Apply all bridge patches (Smart Fader, pad LEDs, VU meters, etc.)
5. Patch control-shim.c with the VU level publisher
6. Write rx3.conf
7. Handle the FT5x06 touch driver
8. Recover the firmware from Pioneer (~110 MB download)
9. Build the chroot
10. Compile fbshim.so
11. Enable and start rx3.service

When it finishes, reboot:

```bash
sudo reboot
```

Install script options

Variable Default Purpose
AUTO_REBOOT 1 Reboot at the end. Set to 0 to review the log first.
VU 0 Enable VU meters (may wedge the FLX4 on some firmware revisions)

Example without auto-reboot:

```bash
AUTO_REBOOT=0 bash rx3-pi4-install.sh
```

---

Verifying after install

```bash
# Is the service running?
systemctl status rx3.service --no-pager

# Is the shim publishing levels?
stat -c '%s' /home/drclab/rx3-rootfs/tmp/rx3-leds
# Expect: 1048

# Are the levels real?
sudo python3 -c "
import struct
d = open('/home/drclab/rx3-rootfs/tmp/rx3-leds','rb').read()
for deck in (1, 2):
    o = 16 + 64*16 + 4*(deck-1)
    print(f'deck {deck}:', struct.unpack_from('<i', d, o)[0])
"
# Play music → deck 1 shows a value like -14, -8, etc.
```

Press the FLX4 buttons:

· Smart Fader → Source screen appears
· Smart CFX → Browse screen appears
· Pad mode buttons → LEDs switch
· Hot cue pads → LEDs toggle
· Play music → VU meters move

---

Updating

The system supports two update methods.

Method 1 — Online (GitHub Actions + Gmail)

When you push changes to your fork of Rx3-flx4, GitHub Actions builds a release and emails you a link. See rx3-usb-update/ for the automated workflow.

Method 2 — Offline (USB stick)

1. Build an update package on your dev machine with make-rx3-update.sh
2. Write it to a USB stick labeled RX3UPDATE
3. Mail the stick to the target Pi's owner
4. They plug it in → green UPDATE OK on screen → unplug

The updater on the Pi:

· Verifies SHA256 checksum before applying
· Backs up the current files
· Rolls back automatically if the service fails to start
· Records the applied version so the same USB can't be applied twice

See rx3-usb-update/README.md for the full workflow.

---

File layout after install

```
/home/drclab/
├── Rx3-flx4/                       # Source tree (from fork or zip)
│   └── rx3-handoff/
│       ├── controller-bridge.py    # FLX4 ↔ RX3 bridge
│       ├── control-shim.c          # Firmware hooks + VU publisher
│       ├── fbshim.c                # Audio/framebuffer hooks
│       ├── rx3-start.sh            # Service entry point
│       └── rx3.conf                # Framebuffer + font config
├── rx3-rootfs/                     # ARM32 chroot
│   ├── lib/fbshim.so               # Compiled shim
│   ├── root/pdj/rbp-pi             # Pioneer firmware
│   └── tmp/rx3-leds                # Published VU levels
├── rx3-fb-present                  # Display presenter binary
├── rx3-touch-bridge                # Touch input helper
├── rx3-pi4-7inch/                  # This repo
│   └── rx3-pi4-install.sh
└── .rx3-usb-version                # Last applied update
```

---

Configuration

rx3.conf

Located at ~/Rx3-flx4/rx3-handoff/rx3.conf:

```ini
RX3_FB=/dev/fb0
RX3_ROTATE=0
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
```

Variable Values Meaning
RX3_FB /dev/fb0 etc. Framebuffer device
RX3_ROTATE 0, 90, 180, 270 Display rotation (clockwise)
RX3_FONT Path to TTF Font used by the presenter

Controller bridge logging

The bridge writes detailed logs to /home/drclab/rx3-controller.log. To disable logging, set RX3_BRIDGE_LOG= to empty in the service environment.

---

Troubleshooting

Screen is black after boot

```bash
# Check the DSI connector
for f in /sys/class/drm/card*-DSI-*/status; do
    echo "$f: $(cat $f)"
done
# Expect: connected

# Check backlight
cat /sys/class/backlight/*/brightness
# Expect: 255

# Check the presenter
cat /home/drclab/rx3-present.log
```

If the connector says connected but the screen is dark, the DSI overlay may be missing. Check /boot/firmware/config.txt for dtoverlay=vc4-kms-dsi-7inch.

FLX4 doesn't respond to any button

```bash
# Is the device detected?
lsusb | grep -i alphatheta
ls /dev/snd/midi*

# Is the bridge running?
pgrep -af controller-bridge

# Watch live input
tail -f /home/drclab/rx3-controller.log
```

If the FLX4 dropped off the USB bus (usually after a MIDI overload), unplug it, wait 15 seconds, plug it back in.

VU meters don't light up

```bash
# Is the shim publishing?
stat -c '%s' /home/drclab/rx3-rootfs/tmp/rx3-leds
# Expect: 1048

# If smaller (1040 or missing), the shim wasn't rebuilt:
cd ~/Rx3-flx4/rx3-handoff
arm-linux-gnueabi-gcc -shared -fPIC -O2 -fomit-frame-pointer -fno-builtin -nostdlib \
    -o ~/rx3-rootfs/lib/fbshim.so fbshim.c control-shim.c
sudo systemctl restart rx3.service
```

FLX4 wedges after a few minutes of playback

This is a known hardware limitation. The FLX4's single MIDI endpoint cannot sustain continuous output while reading input at high rates. The installed configuration (3.3 Hz) is the fastest that has proven stable.

If it still wedges:

1. Unplug and replug the FLX4
2. If the issue returns, disable VU meters by editing controller-bridge.py:
   · Find time.sleep(0.30) in the led_loop function
   · Change to time.sleep(0.50) (2 Hz) or higher
3. Or remove the entire led_loop thread if you don't need VU

---

Uninstall

```bash
sudo systemctl stop rx3.service
sudo systemctl disable rx3.service

# Remove the service
sudo rm /etc/systemd/system/rx3.service
sudo systemctl daemon-reload

# Remove the files
rm -rf ~/Rx3-flx4 ~/rx3-rootfs ~/rx3-fb-present ~/rx3-touch-bridge
rm -f ~/.rx3-usb-version
```

---

Credits

· Pioneer DJ — original XDJ-RX3 firmware
· mutlisensor — the Rx3-flx4 project providing the base bridge and shim architecture
· DRCRecoveryData — this installer and the FLX4-specific patches

---

License

The installer and patches in this repository are provided as-is for personal use. The firmware itself remains the property of AlphaTheta / Pioneer DJ.