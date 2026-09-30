# cfg-guardian

Creality K2 firmware updates rewrite `/mnt/UDISK/printer_data/config` and drop files they did not ship. `printer.cfg` often still has the `[include]` line, so Klipper halts:

```
Include file '/mnt/UDISK//printer_data/config/screws_tilt_adjust.cfg' does not exist
```

The same pass puts stock values back into `gcode_macro.cfg` and `box.cfg`, which wipes the two Phaetus DXC2 edits.

cfg-guardian is a boot service on the printer. It puts those files and lines back, then asks Klipper to restart if the printer is idle. It does not restart during a print.

Tested on a K2 Pro at firmware 1.1.7.0. The K2 and K2 Plus use the same config path. I have not run it on those.

## Install

Run this on the printer as root. No clone, and no `curl` or `wget`. Python 3 is already on the image. It downloads `install.py`, which then downloads the rest, installs it, and deletes the download.

```sh
python3 -c "import urllib.request;exec(urllib.request.urlopen('https://raw.githubusercontent.com/FutureHax/k2pro-cfg-guardian/main/install.py').read())"
```

If you already cloned the repo, run this from the checkout instead:

```sh
python3 install.py
```

From a computer that can already `ssh root@printer`:

```sh
./deploy.sh root@printer
```

The service is `/etc/init.d/cfg-guardian`. It starts before Klipper. A copy of the installer stays at `/mnt/UDISK/cfg-guardian/dist/` because that disk survives an update. If a reset wipes the overlay and UDISK is still there:

```sh
sh /mnt/UDISK/cfg-guardian/dist/install.sh
```

## What it restores

| What | Where |
|---|---|
| `screws_tilt_adjust.cfg` | downloaded at install, then copied back when the file is gone |
| `[include screws_tilt_adjust.cfg]` | put back into `printer.cfg` if the line is gone |
| `G0 E-40 F360` | `QUIT_MATERIAL_RETRUDE_MATERIAL` in `gcode_macro.cfg` |
| `Tn_retrude: -20` | `[box]` in `box.cfg` |
| `G4 P300` | same macro, after the retract. Off unless you set `"enabled": true` |
| `cut_pos_offset` | `[motor_control]` in `motor_control.cfg`. Off. `to` is the community `0.0` |

This project does not include `screws_tilt_adjust.cfg`. Install downloads it from [jglerner/creality-k2-pro-klipper-screws-tilt](https://github.com/jglerner/creality-k2-pro-klipper-screws-tilt/tree/main) (MIT). The two number changes are the firmware steps in the [Phaetus DXC2 manual](https://ncstatic.clewm.net/rsrc/2026/0331/19/d587a2aa12e64674bcc63a0d919fbdf8.pdf).

A change runs only when `"enabled"` is true. If the field is missing, it stays off.

`G4 P300` is a 300 ms pause after that retract, before the CFS reels the filament in. The macro already has `M400`, which waits until the extruder move finishes, so that entry is `"enabled": false`. Set it to true if a filament change still fails with the stub caught in the gears.

`cut_pos_offset` is the cutter depth margin. The widely copied fix changes stock `0.4` to `0.0`, which is what `to` is set to. The entry stays off. `CALIBRATE_CUT_POS` on this printer measured the blade at x=-9.9 and saved `cut_pos_x = -9.50` using the stock `0.4` (`x + offset`), and that cut works. Other people stopped at `0.2`, `0.1`, or `0.05` instead of `0.0`. People describe both in these threads:

- [DXC2 HELP](https://www.reddit.com/r/Creality_k2/comments/1vmwyy1/dxc2_help/) (`G4 P300`, and `cut_pos_offset` 0.0)
- [Some DXC2 Notes](https://www.reddit.com/r/Creality_k2/comments/1vzn218/some_dxc2_notes/) (`G4 P300`, and `cut_pos_offset` 0.1)
- [K2 Plus firmware and DXC2 cfg mods](https://www.reddit.com/r/Creality_k2/comments/1teck2u/k2_plus_v_1155_and_dxc2_cfg_mods/) (`G4 P300`, and `cut_pos_offset` 0.05)
- [Creality forum: Please help with the DXC2](https://forum.creality.com/t/please-help-with-the-dxc2/50837) (`cut_pos_offset` 0.2)

Cutter calibration is stored as `cut_pos_x` in the `SAVE_CONFIG` block of `printer.cfg`.

If you edit a vault file on the printer, that edit becomes the copy kept for next time. The previous vault file is saved next to it as `.bak`.

A DXC2 number you change to something else, not the stock `-10`, is left alone. After the firmware version actually changes, the DXC2 value is written again.

## Check it

```sh
cfg-guardian.sh status
tail -f /mnt/UDISK/cfg-guardian/guardian.log
```

## Add another file

Copy it to `/mnt/UDISK/cfg-guardian/vault/`. If `printer.cfg` should include it, add the `[include name.cfg]` line to `/mnt/UDISK/cfg-guardian/printer.cfg.includes`.

Small edits inside a Creality file go in `/mnt/UDISK/cfg-guardian/patches.json`. Each change names the `file`, the `section`, and either a whole line (`from` / `to`), a `setting` plus `from` / `to`, or `insert_after` plus `line`. It is applied only when `"enabled"` is true. Leaving `enabled` out means off. `src/patches.json` is the DXC2 set.

## What it does not keep

Edits in `printer.cfg` other than `[include]` lines. Creality's own updater replaces that file when the stock `# Version:` header changes, and only the `SAVE_CONFIG` block is carried over. That has not happened on the 1.1.7.0 update. Whole copies of `gcode_macro.cfg` or `box.cfg` are not saved either. Those files change with firmware, so only the named lines in `patches.json` are put back.
