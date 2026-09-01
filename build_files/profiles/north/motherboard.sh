#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# ASUS ProArt B850-Creator WiFi Neo enablement.
# Super I/O: Nuvoton NCT6701D | Wi-Fi: RTL8922AE (rtw89) | LAN: dual Realtek 5GbE
# (RTL8126, r8169). Wi-Fi/LAN/audio work in-kernel on Fedora 44 — nothing to bake
# for them (verify post-install). The board-specific win is sensor/fan access.

### 1. Motherboard sensors + fan access
# ASUS boards let ACPI reserve the Super I/O I/O region, so nct6775 won't load
# and lm_sensors/LACT/fan tools see no motherboard fan RPM, voltages, or board
# temps. acpi_enforce_resources=lax lets the native driver claim the region.
# Tradeoff: the kernel driver and the EC can both touch the Super I/O — the
# standard ASUS fix, low practical risk. Baked declaratively via bootc kargs.d.
#
# TODO(hardware): the NCT6701D is new — fan/voltage read fine, but several temp
# channels read 0C or are missing until asus-ec-sensors gains an entry for this
# board. Recheck on newer kernels. See docs/reference/sensors.md.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/20-sensors.toml << 'EOF'
kargs = ["acpi_enforce_resources=lax"]
match-architectures = ["x86_64"]
EOF

# nct6775 won't auto-probe when the region was ACPI-reserved — force-load it.
cat > /usr/lib/modules-load.d/nct6775.conf << 'EOF'
nct6775
EOF

### 2. CoolerControl — REMOVED 2026-08-18. Do not add it back without reading this.
# It was here for CPU/case/AIO fan curves, as the system-fan counterpart to LACT.
# Two reasons it's gone:
#
# 1. It couldn't actually drive this board's fans — the NCT6701D is too new (same
#    gap as the temp-channel TODO above), so it read sensors and changed nothing.
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
