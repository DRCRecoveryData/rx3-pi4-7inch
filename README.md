# rx3-pi4-7inch

Installer for running XDJ-RX3 firmware emulation on a Raspberry Pi 4 with
a **7" DSI touchscreen** (FocalTech FT5x06 controller, 800×480 landscape).

This fork bundles a **newer** `Rx3-flx4.zip` (91-line `touch-bridge.c`)
directly in the repo, and patches the upstream installer for 7" panels —
the original 5"-Waveshare path blacklists `edt_ft5x06`, which kills touch
on FT5x06-based 7" panels.

## Hardware tested

| Item | Value |
|---|---|
| Pi | Raspberry Pi 4 Model B |
| OS | Raspberry Pi OS Bookworm / Trixie (aarch64) |
| Panel | 7" DSI, 800×480, FT5x06 touch over I²C @ `0x38` |
| Framebuffer | `vc4drmfb` on `/dev/fb0` |
| Touch | `edt_ft5x06` driver → `/dev/input/eventN` |

## Repo contents

- `rx3-pi4-install.sh` — installer (this repo)
- `Rx3-flx4.zip` — the Rx3-flx4 tree (newer than upstream GitHub)

## Quick install

```bash
git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
cd rx3-pi4-7inch
chmod +x rx3-pi4-install.sh
AUTO_REBOOT=0 bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

`AUTO_REBOOT=0` skips the automatic reboot so you can verify the install
first. When ready:

```bash
sudo reboot
```

## What the installer does

1. Appends `usb-storage.quirks=174c:2362:u vt.global_cursor_default=0 consoleblank=0`
   to `/boot/firmware/cmdline.txt` (idempotent).
2. Installs dependencies (`gcc-arm-linux-gnueabi`, `fuse-overlayfs`,
   `uhubctl`, `python3-pil`, `evtest`, `p7zip-full`, `unzip`, …).
3. **Uses `Rx3-flx4.zip`** next to the script if present. Otherwise clones
   the upstream `mutlisensor/Rx3-flx4`. If `~/Rx3-flx4` already exists,
   it's left untouched.
4. Patches `rx3-start.sh` (USB power-cycle disabled, wait loop shortened,
   fb0 unblank).
5. Writes `rx3.conf` for `/dev/fb0` at 800×480, rotation 0.
6. **Touch driver handling** — only blacklists `edt_ft5x06` when the
   official Raspberry Pi 7" touch driver (`raspberrypi_ts`) is loaded.
   On 7" Waveshare-style panels (which use FT5x06), `edt_ft5x06` is
   preserved so touch works.
7. Downloads and decrypts the Pioneer firmware ISO, extracts the cramfs.
8. Builds the chroot at `~/rx3-rootfs`.
9. Compiles helpers (`~/rx3-fb-present`, `~/rx3-touch-bridge`).
10. Installs udev rules, `rx3.service`, disables the desktop, masks
    PipeWire, disables the console cursor.
11. Enables `rx3.service` for auto-start on boot.

## Verify before reboot

```bash
lsmod | grep edt_ft5x06
ls -l /dev/input/event4
udevadm info -q property -n /dev/input/event4 | grep ID_INPUT
grep -nE 'if false &&|seq 1 1|fb0/blank' ~/Rx3-flx4/rx3-handoff/rx3-start.sh
systemctl is-enabled rx3.service
```

Expected:
- `edt_ft5x06 ... 0`
- `/dev/input/event4` present
- `ID_INPUT=1` and `ID_INPUT_TOUCHSCREEN=1`
- Three matching lines from `rx3-start.sh`
- `enabled`

## After reboot

```bash
systemctl status rx3 --no-pager
cat ~/rx3-touch.log
```

`~/rx3-touch.log` should contain a line like:

```
touch bridge: touchscreen, panel 800x480 rotate 0, canvas 1920x1200 at ..., touch 0..799 x 0..479
```

## Troubleshooting

**Blank screen after reboot** — check DSI overlay:
```bash
grep -iE 'dtoverlay|dsi' /boot/firmware/config.txt
```
For most 7" DSI panels, add:
```
dtoverlay=vc4-kms-dsi-7inch
```
and reboot.

**UI appears but touch does nothing**:
```bash
cat ~/rx3-touch.log
systemctl status rx3-pointer --no-pager
udevadm info -q property -n /dev/input/event4 | grep ID_INPUT
dmesg | grep ft5x06
```

**UI rotated wrong** — edit `~/Rx3-flx4/rx3-handoff/rx3.conf`, set
`RX3_ROTATE=180` (or 90/270), then `sudo systemctl restart rx3`.

**Player crashes on start**:
```bash
tail -60 ~/rx3-player.log
journalctl -u rx3 -b --no-pager | tail -40
```

## Updating `Rx3-flx4.zip`

Keep your Windows copy as the source of truth:

1. Edit on Windows.
2. Re-zip:
   ```
   cd C:\Users\drclab\Downloads\Rx3-flx4
   tar -a -c -f Rx3-flx4.zip Rx3-flx4
   ```
3. In this repo: `git rm Rx3-flx4.zip`, copy the new one in,
   `git add Rx3-flx4.zip`, commit, push.
4. On the Pi: `rm -rf ~/Rx3-flx4` then re-run the installer.

## Credits

- `mutlisensor/Rx3-flx4` — original Pi 4 port (5" Waveshare DSI).
- This fork — 7" FT5x06 touch handling, bundled newer zip, zip-first install.
```

## 3. Push both files to GitHub

From your Windows PC, in the folder where you cloned the repo:

```powershell
cd C:\path\to\rx3-pi4-7inch
# copy rx3-pi4-install.sh and README.md here
git add rx3-pi4-install.sh README.md
git commit -m "Add installer and 7-inch README"
git push
```

If you didn't clone yet:
```
git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
cd rx3-pi4-7inch
```

## 4. Test the full flow end-to-end on the Pi

Wipe your existing tree to prove the zip path works:

```bash
rm -rf ~/Rx3-flx4
cd ~
git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
cd rx3-pi4-7inch
ls -lh Rx3-flx4.zip
unzip -t Rx3-flx4.zip | tail -2      # must say "No errors detected"
chmod +x rx3-pi4-install.sh
AUTO_REBOOT=0 bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

In the log you should see:

```
==> Preparing source tree at /home/drclab/Rx3-flx4
    Unzipping /home/drclab/rx3-pi4-7inch/Rx3-flx4.zip -> /home/drclab/
    Unzipped OK
...
==> Checking touch driver
    edt_ft5x06 is the active touch driver (7" DSI) — NOT blacklisting
...
==> INSTALL COMPLETE
Skipping reboot (AUTO_REBOOT=0). Run: sudo reboot
```

Then verify, and reboot:

```bash
lsmod | grep edt_ft5x06
ls -l /dev/input/event4
udevadm info -q property -n /dev/input/event4 | grep ID_INPUT
sudo reboot
