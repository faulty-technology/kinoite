---
date: 2026-09-27
subject: sensor identified — USB 04f3:0c99 "ELAN:ARM-M4", zero public coverage; ELANMOC2 community fork is the fix lead
harness: none (diagnosis continuation) — dmesg on the box; libfprint source archaeology (iafilatov/libfprint elan-github-msg tarball); web search
box: kinoite (laptop)
---

# Sensor identity: 04f3:0c99, and the MOC2 lead

Amends
[2026-09-27-fingerprint-elan-final-verdict](2026-09-27-fingerprint-elan-final-verdict.md)
with the sensor's actual identity and a concrete fix lead. The two-defect
verdict (verification never matches; claims not released after failed
operations) stands.

## Corrections to the record

- **The sensor is USB `04f3:0c99`, product string "ELAN:ARM-M4"** (dmesg:
  `usb 3-5: New USB device found, idVendor=04f3, idProduct=0c99`). It was in
  `lsusb` all along; the first probe grepped for `fingerprint|goodix` and
  missed it because the product string contains neither word.
- **The I²C `i2c-VEN_04F3:00` client was the touchpad** (`04F3:3330`
  Mouse+Touchpad via hid-multitouch), not the sensor — the earlier
  "presumed sensor" guess was wrong. `ELAN3233:00` is the touchscreen.
- Same "ELAN:ARM-M4" product string as the LG Gram case below.

## Findings

- **Zero public coverage for `04f3:0c99`** — no hits in any search. This
  explains the "nobody else has hit this" observation: the reporting
  population for fingerprint-on-Linux is small, Dells skew Windows, and this
  specific Elan revision has no public footprint at all.
- **libfprint's Elan driver matches by vendor id + sensor-dimension
  heuristics, not a per-device table** (the driver documents three reader
  geometries: 144×64, 96×96 rotated, 96×96 normal). So `0c99` binds (fprintd
  names it "Elan MOC Sensors") but its frame-handling/calibration heuristics
  may not fit this revision — consistent with defect 1.
- **Community precedent for sibling IDs:** `04f3:0c4c` / `04f3:0c00` needed a
  separate **ELANMOC2 driver** (Greek64/libfprint-elanmoc2-deb fork);
  `04f3:0ca2` (LG Gram) needed a binary patch to `libfprint-2.so` because it
  was missing from the device table (omarchy discussion #5191, 2026-04).

## Fix lead (new, untested)

If `0c99` speaks the MOC2 protocol, the **Greek64 ELANMOC2 fork** (or a
local build of it with `0c99` added) is the candidate fix. On this bootc
image a raw `/usr/lib` `.so` patch would not survive base updates; the
durable form is a local RPM (or COPR) carrying the patched/forked libfprint.

## Watch list (updated)

1. **The MOC2-fork experiment** — build/test against `0c99`; if verification
   works, package as a local RPM and file the upstream patch.
2. **fprintd / libfprint package updates** — still relevant; re-test with the
   clean protocol (restart fprintd → 30s → one `sudo ls`).
3. Kernel updates — lower priority.
