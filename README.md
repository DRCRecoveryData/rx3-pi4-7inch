# XDJ-RX3 on Raspberry Pi 4 with 7" DSI Display

A complete standalone XDJ-RX3 setup on Raspberry Pi 4 with the official 7" DSI touch panel, driven by a Pioneer DDJ-FLX4 as the physical controller. The RX3 firmware runs in an ARM32 chroot, the UI is presented on the DSI panel, and the FLX4's buttons, faders, LEDs, and audio are bridged into the firmware.

---

## Table of Contents

- [Overview](#overview)
- [Hardware Requirements](#hardware-requirements)
- [Features](#features)
- [Installation](#installation)
- [Controller Mappings](#controller-mappings)
- [Architecture](#architecture)
- [Configuration](#configuration)
- [Applied Fixes](#applied-fixes)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)
- [Updating](#updating)
- [File Layout](#file-layout)
- [Rollback](#rollback)
- [Credits & License](#credits--license)

---

## Overview

This project repurposes a Raspberry Pi 4 as a self-contained XDJ-RX3 player. It recovers the RX3 firmware from Pioneer's official update package, runs it in an ARM32 chroot, presents the UI on the official 7" DSI touch display, and translates the DDJ-FLX4 controller's MIDI into the RX3's internal control protocol.

The result: a working RX3 interface with a real controller, running on ~$100 of Pi hardware instead of the ~$2,000 dedicated unit.

**Base architecture:** derived from [`mutlisensor/Rx3-flx4`](https://github.com/mutlisensor/Rx3-flx4).

---

## Hardware Requirements

| Component | Notes |
|---|---|
| Raspberry Pi 4 | 2 GB / 4 GB / 8 GB — Pi 5 and Pi 3 are **not** supported |
| Official 7" DSI touch panel | 800×480, connects via the DSI ribbon connector |
| Pioneer DDJ-FLX4 | Tested as shipped; latest firmware recommended |
| USB-C power supply | 5.1 V / 3 A minimum |
| MicroSD card | 16 GB or larger, Class 10 or better |
| USB drive (optional) | For offline updates and music media |

---

## Features

### Verified working

- **RX3 UI on the 7" DSI panel** — full firmware interface, touch enabled
- **Audio through the FLX4** — 2-channel master + cue to the controller's USB sound card
- **USB media playback** — removable drives mounted via copy-on-write overlay
- **Autostart on boot** — systemd unit brings everything up
- **SYNC button + LED** — press toggles sync, LED tracks state on both decks
- **Beat FX channel selector** — 1, 2, and 1&2 positions all functional
- **Smart Fader / Smart CFX** — mapped to SOURCE / BROWSE
- **Master Cue / Headphone Cue** — mapped with LED feedback
- **Pad modes + hot cue LEDs** — HOTCUE, PAD FX1, BEAT JUMP, SAMPLER
- **VU meters** — deck level meters driven from firmware state at 3.3 Hz

### Controller support

- **DDJ-FLX4** — fully tested
- **DDJ-400** — supported by the base bridge, not verified on this build

---

## Installation

### Quick start

```bash
git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
cd rx3-pi4-7inch
chmod +x rx3-pi4-install.sh
AUTO_REBOOT=0 bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

### Installer options

| Variable | Default | Description |
|---|---|---|
| `AUTO_REBOOT` | `1` | Reboot when the install finishes |
| `VU` | `0` | Enable VU meter publishing from the shim |
| `RX3_FXCH_BOTH` | `5` (MASTER) | Beat FX target for the "1 & 2" selector position |

### What the installer does

1. Patches `cmdline.txt` with USB quirks and console settings
2. Installs build and runtime dependencies
3. Clones or extracts the source tree to `~/Rx3-flx4/`
4. Patches `rx3-start.sh` for Pi 4 quirks
5. Patches `controller-bridge.py` with all controller mappings and LED handlers
6. Patches `control-shim.c` to publish VU levels
7. Writes `rx3.conf` with display settings
8. Configures the FT5x06 touch driver blacklist
9. Recovers the XDJ-RX3 firmware (~110 MB) from Pioneer
10. Builds the ARM32 chroot at `~/rx3-rootfs/`
11. Compiles `fbshim.so` (with `control-shim.c` linked in)
12. Installs and enables `rx3.service`
13. Verifies and optionally reboots

---

## Controller Mappings

### DDJ-FLX4 → RX3

| FLX4 control | MIDI | RX3 action |
|---|---|---|
| Play | ch 0/1, note 0x0B | Play/pause deck 1/2, LED follows |
| Cue | ch 0/1, note 0x0C | Cue point, LED follows |
| SYNC | ch 0/1, note 0x58 | Toggle sync, LED follows |
| Shift | ch 0/1, note 0x3F | Shift modifier (see below) |
| Hot Cue pads | ch 7/9, notes 0x00–0x07 | Pad A–H hot cue set/jump |
| SHIFT + pad | ch 8/10, notes 0x00–0x07 | Clear pad LED / delete cue |
| Beat FX ON/OFF | ch 4, note 0x47 | Toggle beat FX, LED follows |
| Beat FX CH 1 | ch 4, note 0x10 | FX target = CH1 |
| Beat FX CH 2 | ch 5, note 0x11 | FX target = CH2 |
| Beat FX CH 1&2 | ch 4+5, notes 0x10+0x11 | FX target = MASTER |
| Beat FX select | ch 4, note 0x63/0x64 | Cycle through beat FX list |
| Smart Fader | ch 6, note 0x01 | Open SOURCE screen |
| Smart CFX | ch 6, note 0x00 | Open BROWSE screen |
| Master Cue | ch 6, note 0x63 | Toggle master cue |
| Headphone Cue 1/2 | ch 0/1, note 0x54 | Toggle cue, LED follows |
| Channel fader | ch 0/1, CC 0x13 | Deck level (also scales VU) |
| Pad mode buttons | ch 0/1, notes 0x1B/0x20/0x6D/… | Switch pad mode, LED follows |

### Beat FX list (cyclic via 0x63/0x64)

```
0: DELAY     7: PHASER
1: ECHO      8: FILTER
2: PING PONG 9: TRANS
3: SPIRAL   10: ROLL
4: HELIX    11: SLIP ROLL
5: REVERB   12: PITCH
6: FLANGER  13: VINYL BRAKE
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Raspberry Pi 4 (host, ARM64)                                │
│                                                              │
│  ┌────────────────────┐    ┌─────────────────────────────┐  │
│  │ rx3-fb-present     │◄───│ /dev/fb0 (DSI panel)        │  │
│  │ (draws frames)     │    │ 800×480                     │  │
│  └─────────▲──────────┘    └─────────────────────────────┘  │
│            │                                                 │
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

1. **FLX4 → firmware:** MIDI input → `controller-bridge.py` → `press()`/`send()`/`analog()` → firmware control protocol
2. **Firmware → FLX4 LEDs:** bridge tracks state in Python (play, sync, cue, etc.) → `led()` → MIDI output → FLX4 LED
3. **Firmware → VU meters:** `control-shim.c` reads firmware channel levels → writes to `/tmp/rx3-leds` → bridge's `led_loop()` polls at 3.3 Hz → MIDI CC 0x02 → FLX4 VU meters
4. **Firmware audio → FLX4:** firmware writes PCM to `hw:CARD=DDJFLX4` → FLX4's USB audio output → headphones / RCA master

---

## Configuration

### `~/Rx3-flx4/rx3-handoff/rx3.conf`

Loaded by `rx3-env.sh` at every script start. Common settings:

```bash
RX3_FB=/dev/fb0                                       # framebuffer to draw on
RX3_ROTATE=0                                          # 0/90/180/270 clockwise
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

---

## Applied Fixes

### Fix 1 — SYNC button LED

**Symptom:** Pressing SYNC on either deck did nothing; the LED stayed dark.

**Cause:** `controller-bridge.py` mapped note `0x58` to the name `'sync'`, but the dispatcher had no `if name == 'sync':` branch, so the press was silently dropped.

**Fix:** Added a `sync_on` state dict and a handler:

```python
sync_on = {1: False, 2: False}

# ...in the dispatcher:
if name == 'sync':
    if down:
        sync_on[deck] = not sync_on[deck]
        press(K['sync'], deck, True)
    else:
        press(K['sync'], deck, False)
    led(0x90 + deck - 1, 0x58, sync_on[deck])
```

**Verification:**

```bash
sudo systemctl stop rx3.service
amidi -p hw:3,0,0 -S "90 58 7F"   # deck 1 SYNC on
amidi -p hw:3,0,0 -S "90 58 00"   # deck 1 SYNC off
amidi -p hw:3,0,0 -S "91 58 7F"   # deck 2 SYNC on
amidi -p hw:3,0,0 -S "91 58 00"   # deck 2 SYNC off
sudo systemctl start rx3.service
```

### Fix 2 — Beat FX "1 & 2"

**Symptom:** Beat FX channel selector worked for "1" and "2", but "1 & 2" selected only deck 2 (or nothing).

**Cause:** The FLX4 does not send a third note for "1 & 2". It fires **both** selector notes back-to-back:

```
Note on  ch 4, note 0x10   ← "1"
Note on  ch 5, note 0x11   ← "2"
```

The bridge processed each independently, so the second overwrote the first.

**Fix:** Added a 40 ms debounce in the CH SELECT handler:

```python
FXCH_BOTH = int(os.environ.get('RX3_FXCH_BOTH', str(FXCH_MASTER)))
fx_sel_last = {}

# ...in the handler:
if n in (0x10, 0x11, 0x14) and down:
    now = time.time()
    fx_sel_last[(ch, n)] = now
    other = (5, 0x11) if (ch, n) == (4, 0x10) else (4, 0x10)
    if n in (0x10, 0x11) and (now - fx_sel_last.get(other, 0)) < 0.04:
        sel = FXCH_BOTH
    else:
        sel = CTL['fxch'].get((ch, n), 'master')
        sel = FXCH_MASTER if sel == 'master' else sel
    send(K['fxch'], 5, 0, sel, float(sel))
    return
```

**Value:** `FXCH_BOTH` defaults to `FXCH_MASTER` (5). The RX3 firmware's Beat FX CH list is `0=CH1, 1=CH2, 2=MIC, 3=CF.A, 4=CF.B, 5=MASTER` — there is no native "1 & 2". MASTER is the closest equivalent: FX applied to both channels via the master bus.

To try other values:

```bash
export RX3_FXCH_BOTH=6   # or 7, 8, 255...
sudo systemctl restart rx3.service
```

If nothing else works, MASTER is the practical ceiling.

---

## Troubleshooting

### Black screen

**Symptom:** The Pi boots, service starts, but the 7" panel shows nothing.

**Checks:**

```bash
# Is the framebuffer present?
ls /dev/fb*
cat /sys/class/graphics/fb0/name

# Is the presenter running?
ps aux | grep rx3-fb-present

# Presenter logs
tail -40 ~/rx3-present.log
```

**Fix:** The DSI framebuffer is created at boot, not on hotplug. If the panel was connected after boot, reboot with it attached.

### No audio

**Symptom:** The firmware loads, the RX3 UI responds, but nothing comes out of the FLX4.

**Checks:**

```bash
# Is the FLX4's audio device free?
aplay -l | grep -A1 DDJ
# Subdevices: 1/1  → free, good
# Subdevices: 0/1  → held by another process

# Who's holding it?
sudo fuser -v /dev/snd/*

# What card did the firmware open?
cat ~/rx3-rootfs/etc/rx3-ctl
# Should be: hw:CARD=DDJFLX4
```

**Fixes, in order:**

1. Restart the service: `sudo systemctl restart rx3.service`
2. Move both channel faders on the FLX4 — firmware reads fader position once at boot, and the bridge mirrors physical position
3. Toggle MASTER CUE off in the RX3 UI
4. Power cycle the FLX4: unplug USB, unplug Pi, wait 15 s, plug FLX4 back in, power on

### FLX4 wedges after a few minutes

**Symptom:** MIDI input stops responding, VU meters freeze, LEDs stay lit.

**Cause:** The FLX4 has a single USB MIDI endpoint that stalls under sustained polling.

**Mitigation:** The bridge polls at 3.3 Hz — the fastest stable rate. If it still wedges, restart the service. If it persists, power-cycle the FLX4.

### VU meters don't light

**Checks:**

```bash
ls -la /tmp/rx3-leds           # or in the chroot's /tmp
cat /tmp/rx3-leds | xxd | head -5
# Should start with: 52 58 4c 31 ("RXL1")

ps aux | grep rbp-pi            # firmware running?
```

If `/tmp/rx3-leds` doesn't exist, the shim isn't loaded. Check that `fbshim.so` in the chroot contains the `led_thread` symbol:

```bash
arm-linux-gnueabi-nm ~/rx3-rootfs/lib/fbshim.so | grep led_thread
```

If missing, rebuild:

```bash
cd ~/Rx3-flx4/rx3-handoff
arm-linux-gnueabi-gcc -shared -fPIC -O2 -fomit-frame-pointer -fno-builtin -nostdlib \
    -o ~/rx3-rootfs/lib/fbshim.so fbshim.c control-shim.c
sudo systemctl restart rx3.service
```

### SYNC or Beat FX stop working after an edit

Check your backups:

```bash
ls -la ~/Rx3-flx4/rx3-handoff/controller-bridge.py*
```

Restore the most recent known-good copy and restart.

---

## Known Limitations

1. **"1 & 2" is MASTER, not a true pre-fader both-channels mode.** The RX3 firmware doesn't expose one. Sonically close, not identical.

2. **Audio can go silent after a restart.** Cause is usually fader position at boot or the FLX4 wedging. See [No audio](#no-audio).

3. **`/tmp/rx3-leds` is a VU-level file, not a button-LED file.** Named misleadingly. Only `control-shim.c` writes it, only the bridge reads it, and it carries channel levels only.

4. **Pi 5 is not supported.** The firmware chroot, display pipeline, and USB handling are Pi 4 specific.

5. **Only the official 7" DSI panel is tested.** The Raspberry Pi Touch Display 2 and HDMI are handled by other branches of the upstream project.

6. **Single MIDI endpoint.** The FLX4 can wedge under sustained polling. Polling rate is capped at 3.3 Hz as a compromise.

7. **No native beat FX "both channels" mode.** MASTER is the closest equivalent.

---

## Updating

### Online

1. Push changes to your fork.
2. GitHub Actions builds a release and emails a download link.
3. Download and copy to a USB stick labeled `RX3UPDATE`.
4. Plug the stick into the Pi; the updater runs on next boot.

### Offline

```bash
# On the build machine:
bash make-update-usb.sh /media/usb/RX3UPDATE

# On the Pi:
sudo mount /dev/sda1 /mnt
cp -r /mnt/RX3UPDATE ~/
sudo bash ~/RX3UPDATE/apply-update.sh
```

The updater verifies SHA256 checksums, backs up replaced files, rolls back on failure, and records the applied version.

---

## File Layout

After installation:

```
~/Rx3-flx4/
└── rx3-handoff/
    ├── controller-bridge.py         # main bridge (patched)
    ├── control-shim.c               # VU publisher (patched)
    ├── fbshim.c                     # framebuffer shim
    ├── rx3-start.sh                 # boot launcher (patched)
    ├── rx3-stop.sh                  # shutdown
    ├── rx3-env.sh                   # environment resolution
    ├── rx3.service.in               # systemd template
    ├── rx3.conf                     # per-machine settings
    ├── install.sh                   # local installer
    ├── build-rootfs.sh              # chroot builder
    ├── recover-firmware.py          # Pioneer downloader
    └── legacy/                      # archived backups

~/rx3-rootfs/                        # ARM32 chroot
├── root/pdj/rbp-pi                  # RX3 firmware
├── lib/fbshim.so                    # compiled shim
├── dev/rx3-ctl                      # card pointer for firmware
└── etc/asound.conf                  # dmix config

~/rx3-usb/                           # USB copy-on-write overlays
~/rx3-player.log                     # firmware stdout
~/rx3-present.log                    # presenter log
/etc/systemd/system/rx3.service      # installed unit
```

---

## Rollback

Every patch run leaves a timestamped backup:

```bash
ls -la ~/Rx3-flx4/rx3-handoff/controller-bridge.py.bak-*
```

Restore:

```bash
cp ~/Rx3-flx4/rx3-handoff/controller-bridge.py.bak-<stamp> \
   ~/Rx3-flx4/rx3-handoff/controller-bridge.py
sudo systemctl restart rx3.service
```

A known-good snapshot after the SYNC + Beat FX fixes is kept as:

```
~/Rx3-flx4/rx3-handoff/controller-bridge.py.working-sync-fxboth
```

---

## Credits & License

### Credits

- **Pioneer DJ / AlphaTheta** — original XDJ-RX3 firmware and hardware design
- **mutlisensor** — the [`Rx3-flx4`](https://github.com/mutlisensor/Rx3-flx4) project providing the base bridge architecture, shim, and firmware port
- **DRCRecoveryData** — this installer, Pi 4 adaptations, and FLX4-specific patches

### License

The installer, patches, and documentation in this repository are provided **as-is** for **personal use**. No warranty, express or implied.

The XDJ-RX3 firmware remains the property of AlphaTheta / Pioneer DJ. This project does not distribute the firmware; it downloads the official update package from Pioneer's servers and extracts the necessary files locally. Do not redistribute the extracted firmware.

Reverse-engineering and interoperability work is provided for personal, non-commercial use. Comply with all applicable laws in your jurisdiction.

---

## Support

Issues, patches, and hardware compatibility reports are welcome via GitHub Issues. Please include:

- Pi model and RAM
- Display model
- Controller model and firmware version
- Output of `sudo journalctl -u rx3.service -n 100 --no-pager`
- Contents of `~/rx3-player.log` (last 50 lines)
- Whether the issue reproduces after a full power cycle
