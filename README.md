# XDJ-RX3 on Raspberry Pi 4 + 7" DSI + DDJ-FLX4

Standalone XDJ-RX3 player running on a Raspberry Pi 4, presented on the
official 7" DSI touch panel, controlled by a Pioneer DDJ-FLX4.

Built on the [`mutlisensor/Rx3-flx4`](https://github.com/mutlisensor/Rx3-flx4)
research project, with Pi 4 adaptations for the official DSI panel.

---

## Table of Contents

- [Overview](#overview)
- [Hardware Requirements](#hardware-requirements)
- [Features](#features)
- [Installation](#installation)
- [Controller Mappings](#controller-mappings)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)
- [File Layout](#file-layout)
- [Updating](#updating)
- [Credits & License](#credits--license)

---

## Overview

This project runs the XDJ-RX3 firmware on a Raspberry Pi 4 in an ARM32
chroot, presents the UI on the official 7" DSI panel, and bridges the
DDJ-FLX4 controller's MIDI, LEDs, and audio into the firmware.

The base code comes from `mutlisensor/Rx3-flx4` (`7inch` branch), which
targets the Pi 5 and the Raspberry Pi Touch Display 2. This build adapts
it for the Pi 4 and the official 7" DSI panel, which use different
overlays and GPIO.

The result: a working RX3 interface with a real DJ controller on
~$100 of Pi hardware instead of the ~$2,000 dedicated unit.

---

## Hardware Requirements

| Component | Notes |
|---|---|
| Raspberry Pi 4 | 2 / 4 / 8 GB. Pi 5 and Pi 3 are **not** supported. |
| Official 7" DSI panel | 800×480, connects via the DSI ribbon connector |
| Pioneer DDJ-FLX4 | Tested as shipped; latest firmware recommended |
| USB-C power supply | 5.1 V / 3 A minimum |
| microSD card | 16 GB or larger, Class 10 |
| USB drive (optional) | For offline updates and music media |

---

## Features

### Verified working

- **RX3 UI on the 7" DSI panel** — full firmware interface, touch enabled
- **Audio through the FLX4** — 2-channel master + cue via the controller's USB sound card
- **USB media playback** — removable drives mounted via copy-on-write overlay
- **Autostart on boot** — systemd unit brings everything up
- **Button LEDs** — PLAY, CUE, SYNC, HP CUE, MASTER CUE, Beat FX, pads
- **Beat FX** — 1, 2, and 1&2 positions all functional
- **Smart Fader / Smart CFX** — mapped to SOURCE / BROWSE
- **Pad modes** — HOTCUE, PAD FX1, BEAT JUMP, SAMPLER
- **VU meters** — deck level meters driven from firmware state at 3.3 Hz

### Controller support

- **DDJ-FLX4** — fully tested
- **DDJ-400** — supported by the base bridge, not verified on this build

---

## Installation

### Prerequisites

- Fresh Raspberry Pi OS 64-bit (Bookworm or newer) on the SD card
- Boot the Pi once with the 7" DSI panel attached
- Connect to Wi-Fi or Ethernet
- Run updates: `sudo apt update && sudo apt full-upgrade -y`

### Quick start

```bash
git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
cd rx3-pi4-7inch
chmod +x setup-mutlisensor.sh
bash setup-mutlisensor.sh 2>&1 | tee ~/setup-mutlisensor.log
```

### What the setup script does

1. Installs build and runtime dependencies
2. Adds `dtoverlay=vc4-kms-dsi-7inch` to `config.txt`
3. Adds USB storage quirks to `cmdline.txt`
4. Clones `mutlisensor/Rx3-flx4` and checks out the `7inch` branch
5. Patches `rx3-start.sh` for Pi 4 quirks (USB power-cycle, fb unblank)
6. Stops and points you to the upstream `INSTALL.md`

### Manual steps after the script

The mutlisensor project does **not** ship an automated installer. After
running the setup script above, follow their `INSTALL.md` by hand:

```bash
sudo reboot                          # apply DSI overlay + cmdline
cd ~/Rx3-flx4
cat README.md
cat INSTALL.md 2>/dev/null
```

Their docs will walk you through:

- Recovering the XDJ-RX3 v1.19 firmware from Pioneer (~110 MB)
- Building the ARM32 chroot at `~/rx3-rootfs/`
- Compiling `fbshim.so`
- Installing and enabling the systemd service
- Connecting the controller

### Firmware

The XDJ-RX3 v1.19 firmware is **not** included and is **not**
redistributed. Download the official update package from Pioneer
(AlphaTheta) and extract the necessary files locally. The upstream
`INSTALL.md` explains where they go.

---

## Controller Mappings

### DDJ-FLX4 → RX3

| FLX4 control | MIDI | RX3 action |
|---|---|---|
| Play | ch 0/1, note 0x0B | Play/pause deck 1/2, LED follows |
| Cue | ch 0/1, note 0x0C | Cue point, LED follows |
| SYNC | ch 0/1, note 0x58 | Toggle sync, LED follows |
| Shift | ch 0/1, note 0x3F | Shift modifier |
| Hot Cue pads | ch 7/9, notes 0x00–0x07 | Pad A–H hot cue set/jump |
| SHIFT + pad | ch 8/10, notes 0x00–0x07 | Clear cue / LED |
| Beat FX ON/OFF | ch 4, note 0x47 | Toggle beat FX, LED follows |
| Beat FX CH 1 | ch 4, note 0x10 | FX target = CH1 |
| Beat FX CH 2 | ch 5, note 0x11 | FX target = CH2 |
| Beat FX CH 1&2 | ch 4+5, notes 0x10+0x11 | FX target = MASTER |
| Beat FX select | ch 4, note 0x63/0x64 | Cycle through FX list |
| Smart Fader | ch 6, note 0x01 | Open SOURCE |
| Smart CFX | ch 6, note 0x00 | Open BROWSE |
| Master Cue | ch 6, note 0x63 | Toggle master cue |
| Headphone Cue 1/2 | ch 0/1, note 0x54 | Toggle cue, LED follows |
| Channel fader | ch 0/1, CC 0x13 | Deck level (also scales VU) |
| Pad mode buttons | ch 0/1, notes 0x1B/0x20/0x6D/… | Switch pad mode, LED follows |

### Beat FX list (cyclic via 0x63/0x64)

```
0: DELAY      7: PHASER
1: ECHO       8: FILTER
2: PING PONG  9: TRANS
3: SPIRAL    10: ROLL
4: HELIX     11: SLIP ROLL
5: REVERB    12: PITCH
6: FLANGER   13: VINYL BRAKE
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Raspberry Pi 4 (host, ARM64)                                │
│                                                              │
│  ┌────────────────────┐    ┌─────────────────────────────┐  │
│  │ rx3-fb-present     │◄───│ /dev/fb0 (7" DSI panel)     │  │
│  │ (draws frames)     │    │ 800×480                     │  │
│  └─────────▲──────────┘    └─────────────────────────────┘  │
│            │ framebuffer                                     │
│  ┌─────────┴──────────────────────────────────────────────┐ │
│  │ rx3-rootfs (ARM32 chroot)                              │ │
│  │                                                         │ │
│  │  ┌─────────────┐    LD_PRELOAD=/lib/fbshim.so          │ │
│  │  │ rbp-pi      │◄─── + control-shim.o                   │ │
│  │  │ (firmware)  │                                        │ │
│  │  └──┬────────┬─┘                                        │ │
│  │     │        │                                          │ │
│  │     │        └─► /tmp/rx3-leds (VU levels)              │ │
│  │     │                                                   │ │
│  │     └─► ALSA: hw:CARD=DDJFLX4 (4ch dmix)                │ │
│  │                                                         │ │
│  └─────────────────────────────────────────────────────────┘ │
│            ▲                                                 │
│            │ control writes                                  │
│  ┌─────────┴──────────┐      ┌───────────────────────────┐   │
│  │ controller-bridge  │◄────►│ DDJ-FLX4 (USB MIDI + Audio)│   │
│  │ (Python)           │      └───────────────────────────┘   │
│  └────────────────────┘                                       │
│                                                              │
│  ┌────────────────────┐                                      │
│  │ rx3-touch-bridge   │◄── /dev/input/event* (touch)         │
│  └────────────────────┘                                      │
└─────────────────────────────────────────────────────────────┘
```

### Data flow

1. **FLX4 → firmware:** MIDI input → `controller-bridge.py` → `press()` / `send()` / `analog()` → firmware control FIFO
2. **Firmware → FLX4 LEDs:** `FirmwareLeds` reads LED state → `led_set()` → MIDI output → FLX4 LED
3. **Firmware → VU meters:** firmware channel levels → `/tmp/rx3-leds` → bridge polls at 3.3 Hz → MIDI CC 0x02 → FLX4 VU meters
4. **Firmware audio → FLX4:** firmware writes PCM to `hw:CARD=DDJFLX4` → FLX4's USB audio output → headphones / RCA master

---

## Configuration

### `~/Rx3-flx4/rx3-handoff/rx3.conf`

Loaded by `rx3_env.py` at every script start. Common settings:

```bash
RX3_FB=/dev/fb0
RX3_ROTATE=0
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `RX3_FXCH_MASTER` | `5` | Firmware value for MASTER FX target |
| `RX3_FXCH_BOTH` | `FXCH_MASTER` | Firmware value for FLX4's "1 & 2" position |
| `RX3_NO_CONTROLLER` | `0` | Set to 1 to skip controller auto-detect |
| `RX3_FB` | auto | Override framebuffer picker |
| `RX3_ROTATE` | auto | Override rotation |
| `RX3_CONTROLLER` | auto | Force `flx4` or `ddj400` profile |

---

## Troubleshooting

### Black screen

**Symptom:** The Pi boots, service starts, but the 7" panel shows nothing.

**Checks:**

```bash
ls /dev/fb*
cat /sys/class/graphics/fb0/name
ps aux | grep rx3-fb-present
tail -40 ~/rx3-present.log
```

**Cause:** The DSI framebuffer is created at boot, not on hotplug. If
the panel was connected after boot, reboot with it attached.

**Verify the overlay is active:**

```bash
grep dsi /boot/firmware/config.txt
dmesg | grep -iE "dsi|panel"
```

Expected: `vc4-kms-dsi-7inch` in `config.txt` and a "panel detected"
message in `dmesg`.

### No audio

**Symptom:** The firmware loads, the RX3 UI responds, but nothing comes
out of the FLX4.

**Checks:**

```bash
aplay -l | grep -A1 DDJ
# Subdevices: 1/1  → free, good
# Subdevices: 0/1  → held by another process

sudo fuser -v /dev/snd/*
cat ~/rx3-rootfs/etc/rx3-ctl
# Should be: hw:CARD=DDJFLX4
```

**Fixes, in order:**

1. `sudo systemctl restart rx3.service`
2. Move both channel faders on the FLX4 — firmware reads fader position once at boot
3. Toggle MASTER CUE off in the RX3 UI
4. Power-cycle the FLX4: unplug USB, unplug Pi, wait 15 s, plug FLX4 back in, power on

### FLX4 wedges after a few minutes

**Symptom:** MIDI input stops responding, VU meters freeze, LEDs stay
lit.

**Cause:** The FLX4 has a single USB MIDI endpoint that can stall under
sustained polling.

**Mitigation:** VU polling is capped at 3.3 Hz — the fastest stable
rate. If it still wedges, restart the service. If it persists,
power-cycle the FLX4.

### Beat FX "1 & 2" applies to only one deck

**Symptom:** The Beat FX CH selector works for "1" and "2", but "1 & 2"
applies FX to one deck only.

**Cause:** The FLX4 fires both selector notes back-to-back for the
"1 & 2" position. Without a debounce, the second overwrites the first.

**Fix:** This is fixed upstream. If you hit it, your clone is behind
`7inch` — run `cd ~/Rx3-flx4 && git pull origin 7inch` and restart the
service. If it still happens, the upstream fix hasn't landed yet:

```python
FXCH_BOTH   = int(os.environ.get('RX3_FXCH_BOTH', str(FXCH_MASTER)))
fx_sel_last = {}
```

Apply the 40 ms debounce to the CH SELECT handler in
`controller-bridge.py`, then `sudo systemctl restart rx3.service`.

### VU meters don't light

**Checks:**

```bash
ls -la ~/rx3-rootfs/tmp/rx3-leds
cat ~/rx3-rootfs/tmp/rx3-leds | xxd | head -5
# Should start with: 52 58 4c 31 ("RXL1")

ps aux | grep rbp-pi
```

If `/tmp/rx3-leds` doesn't exist, the shim isn't loaded. Rebuild it:

```bash
cd ~/Rx3-flx4/rx3-handoff
arm-linux-gnueabi-gcc -shared -fPIC -O2 -fomit-frame-pointer -fno-builtin -nostdlib \
    -o ~/rx3-rootfs/lib/fbshim.so fbshim.c control-shim.c
sudo systemctl restart rx3.service
```

### `rx3.service` won't start

```bash
sudo systemctl status rx3.service
sudo journalctl -u rx3.service -n 80 --no-pager
```

Common causes:

- The chroot at `~/rx3-rootfs/` isn't built (run their `INSTALL.md` steps)
- The firmware binary isn't extracted (recover it from Pioneer's package)
- `fbshim.so` is missing from `~/rx3-rootfs/lib/`

---

## Known Limitations

1. **"1 & 2" maps to MASTER, not a native pre-fader both-channels mode.**
   The RX3 firmware's Beat FX CH list has no pre-fader "both channels"
   value. MASTER is the closest equivalent — FX applied to both channels
   via the master bus.

2. **Audio can go silent after a restart.** Cause is usually fader
   position at boot, or the FLX4 wedging on its single USB endpoint.
   See [No audio](#no-audio).

3. **`/tmp/rx3-leds` is a VU-level file, not a button-LED file.** Named
   misleadingly. Only `control-shim.c` writes it; only the bridge reads
   it; it carries channel levels only.

4. **Pi 5 is not supported.** The chroot, display pipeline, and USB
   handling here are Pi 4 specific. The upstream project targets Pi 5.

5. **Only the official 7" DSI panel is tested.** The Raspberry Pi Touch
   Display 2 and HDMI are handled by other branches upstream.

6. **Single MIDI endpoint.** The FLX4 can wedge under sustained polling.
   Polling is capped at 3.3 Hz as a compromise.

7. **No automated installer.** The upstream project is a research
   repository, not a finished port. Setup is manual after the script.

---

## File Layout

After installation:

```
~/Rx3-flx4/
├── README.md
├── INSTALL.md
└── rx3-handoff/
    ├── controller-bridge.py      bridge (patched for Pi 4 if needed)
    ├── rx3_env.py                environment resolution
    ├── controllers.py            controller profiles
    ├── control-shim.c            control FIFO + VU publisher
    ├── fbshim.c                  framebuffer shim
    ├── rx3-start.sh              boot launcher
    ├── rx3-stop.sh               shutdown
    ├── rx3.service.in            systemd template
    └── ...other support files

~/rx3-rootfs/                     ARM32 chroot
├── root/pdj/rbp-pi               RX3 firmware
├── lib/fbshim.so                 compiled shim
├── dev/rx3-ctl
└── etc/asound.conf

~/rx3-player.log                  firmware stdout
~/rx3-present.log                 presenter log
/etc/systemd/system/rx3.service   installed unit
```

---

## Updating

The upstream project changes frequently. To pull updates:

```bash
cd ~/Rx3-flx4
git stash                       # save any local changes
git pull origin 7inch
git stash pop                   # reapply local changes
sudo systemctl restart rx3.service
```

If the pull introduces conflicts (e.g. your Pi 4 `rx3-start.sh` patches),
resolve them, then:

```bash
git add -p
git commit -m "reapply Pi 4 adaptations"
```

Always back up a working `controller-bridge.py` before updating:

```bash
cd ~/Rx3-flx4/rx3-handoff
cp controller-bridge.py controller-bridge.py.$(date +%Y%m%d-%H%M%S).bak
```

---

## Rollback

To revert to a previous version:

```bash
cd ~/Rx3-flx4
git log --oneline -10           # find the commit you want
git checkout <commit-hash>
sudo systemctl restart rx3.service
```

To go back to the branch tip:

```bash
git checkout 7inch
```

---

## Credits & License

### Credits

- **Pioneer DJ / AlphaTheta** — XDJ-RX3 firmware and hardware design
- **mutlisensor** — the [`Rx3-flx4`](https://github.com/mutlisensor/Rx3-flx4)
  project providing the base bridge, shim, and firmware port
- **DRCRecoveryData** — Pi 4 adaptations for the official 7" DSI panel

### License

The setup script and Pi 4 adaptations are provided **as-is** for
personal use. No warranty, express or implied.

The XDJ-RX3 firmware remains the property of AlphaTheta / Pioneer DJ.
This project does not distribute the firmware; you must download the
official update package from Pioneer and extract it locally. Do not
redistribute the extracted firmware.

Reverse-engineering and interoperability work is provided for personal,
non-commercial use. Comply with all applicable laws in your jurisdiction.

---

## Support

Issues, patches, and hardware compatibility reports are welcome via
GitHub Issues. Please include:

- Pi model and RAM
- Display model
- Controller model and firmware version
- Output of `sudo journalctl -u rx3.service -n 100 --no-pager`
- Contents of `~/rx3-player.log` (last 50 lines)
- Whether the issue reproduces after a full power cycle
