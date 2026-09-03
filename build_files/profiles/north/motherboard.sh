#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# ASUS ProArt B850-Creator WiFi Neo enablement.
# Super I/O: Nuvoton NCT6701D (reported as nct6799 by the kernel) | Wi-Fi: RTL8922AE
# (rtw89) | LAN: dual Realtek 5GbE (RTL8126, r8169). Wi-Fi/LAN/audio work in-kernel on
# Fedora 44 — nothing to bake for them (verify post-install). The board-specific win is
# sensor/fan access.

### 1. Motherboard sensors + fan access
# The nct6799 driver loads without acpi_enforce_resources=lax and without a force-load
# in modules-load.d. Both were shipped in earlier images but never actually took effect:
# bootc kargs.d did not deliver the karg, and the driver probed itself anyway. Verified
# on Fedora 44 kernel by checking /proc/cmdline and sensors output — full voltage, fan
# RPM and most temps present with neither aid. If a future kernel stops auto-probing,
# the karg + force-load can return; for now they are dead weight.
#
# Three PCH temp channels (PCH_CHIP_CPU_MAX_TEMP, PCH_CHIP_TEMP, PCH_CPU_TEMP) read 0°C
# — a driver quirk, not a sensor-gap. See docs/reference/sensors.md.

### 2. CoolerControl — REMOVED 2026-08-18. Do not add it back without reading this.
# It was here for CPU/case/AIO fan curves, as the system-fan counterpart to LACT.
# Two reasons it's gone:
#
# 1. It couldn't actually drive this board's fans — the nct6799 driver reports fan
#    RPM but CoolerControl couldn't write curves, so it read sensors and changed nothing.
# 2. `coolercontrold` polls GPU hwmon about once a second, and every amdgpu hwmon
#    read calls pm_runtime_get_sync() then pm_runtime_mark_last_busy(). That resets
#    the 5s autosuspend timer forever, so neither R9700 could EVER runtime-suspend.
#    Result: both cards sat awake at ~1950 RPM (30% of 6500) permanently. This cost
#    a long investigation that misdiagnosed it as an amdgpu firmware fan floor —
#    see docs/explanation/gpu-power-and-fans.md.
#
# Anything that continuously polls GPU hwmon has this effect. Weigh idle noise
# against monitoring before enabling such a daemon here. `lactd` has the same
# behaviour and is kept deliberately, because it applies the power cap/undervolt.
