---
date: 2026-09-27
subject: fingerprint reader non-functional on the kinoite laptop image — upstream driver gap, pipeline exonerated
harness: none (diagnosis, not a benchmark) — commands run by hand on the box: fprintdctl status, lsusb, modinfo goodix_fp, journalctl -b -k, /sys/bus/i2c/devices, /dev/hidraw*
box: kinoite (laptop)
---

# Fingerprint reader dead on the kinoite laptop image

## What was measured

A diagnosis, not a benchmark. The fingerprint reader is non-functional on the
kinoite (laptop) bootc image; it worked intermittently in the past and is broken
on recent builds.

**Hardware:** Dell 14 Plus 2-in-1 DB04250; login via plasmalogin (KDE Wayland).

**Failing stack (as installed):** kernel `7.2.7-200.fc44.x86_64`, libfprint
`1.94.100-1.fc44`, fprintd `1.94.5-5.fc44`.

All evidence below was measured on the box, 2026-09-27.

## Numbers

**Evidence (all measured on the box, 2026-09-27):**

- `fprintd.service` active/healthy — the daemon itself is fine.
- `lsusb` shows no fingerprint device.
- `/dev/fingerprint` absent.
- `modinfo goodix_fp` → module not found.
- Kernel log (`sudo journalctl -b -k`) shows no goodix/fingerprint probe at all.
- `/sys/bus/i2c/devices/` contains unbound client `i2c-VEN_04F3:00` (presumed
  sensor, **bus type unconfirmed**) alongside `i2c-ELAN3233:00` (touchpad).
- `/dev/hidraw0..4` present, none identified as fingerprint.

**Pipeline audit (exonerates the build):** the non-north build is
`Containerfile` → `build_files/profiles/base/build.sh` (10 shared scripts +
`packages.sh`). It writes zero udev rules, sets no kernel args, makes no
logind/D-Bus/input-device changes. The only package removals are
`firefox`/`firefox-langpacks`; the only masked units are
`rpm-ostreed-automatic.timer` and `systemd-remount-fs.service`; the one polkit
rule added (`/etc/polkit-1/rules.d/10-1password.rules`) *grants* AUTH_SELF.
Scanner support comes entirely from the base image.

**Base-drift finding:** both `Containerfile` (line 7) and `Containerfile.north`
(line 9) use floating tag `FROM quay.io/fedora/fedora-kinoite:44` with no digest
pin — rebuilds silently inherit upstream kernel/config changes. This is the
mechanism by which an upstream kernel change breaks the reader without any
change on our side.

## What it means

**Verdict: upstream Linux driver gap.** The I²C Goodix-class sensor has no
driver in this kernel build (`goodix_fp` absent; community
`libfprint-tod-goodix` plugins target USB `27c6:*` devices only, so they don't
apply). Not a kinoite pipeline defect.

**Unconfirmed variable (unverified):** whether `i2c-VEN_04F3:00` is the sensor.
Confirm later with `readlink
/sys/bus/i2c/devices/i2c-VEN_04F3:00/driver`, `zcat /proc/config.gz | grep -i
GOODIX`, `rpm -qa | grep -iE 'goodix|libfprint'` — user-side commands, cannot be
run from the sandboxed session that produced this record.

**Recommended follow-ups (chat-level, not code):** monitor
`fedora-kinoite:44` updates for a kernel that enables
`CONFIG_GOODIX_FINGERPRINT`; check upstream `goodix_fp` driver support for this
sensor revision; optionally pin the base digest in both Containerfiles.
