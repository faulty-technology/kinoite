#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# AMD 9900X (Zen 5) + dual R9700 (RDNA4) tunings for a gaming + local-LLM box.

### 1. vm.max_map_count
# Fedora's default (1048576) is fine for most workloads, but the SteamOS value
# fixes a class of Proton games that hang/crash on the lower limit and also helps
# memory-mapped model loading in LLM runtimes (large mmap counts). No downside.
cat > /usr/lib/sysctl.d/99-north.conf << 'EOF'
vm.max_map_count=2147483642
EOF

### 2. amdgpu powerplay controls (baked kernel arg)
# Unlocks OverDrive so clock and voltage offsets are adjustable (e.g. via LACT
# below). Still required on RDNA4 — this is not a legacy Vega/Navi1 thing. Power
# caps (`power1_cap`) work without it; the offsets don't.
#
# 0xfff7ffff, not the 0xffffffff every guide repeats: the driver default is
# 0xfff7bfff and OverDrive is PP_OVERDRIVE_MASK (0x4000), so this is exactly
# "default + OverDrive". 0xffffffff would additionally set PP_GFX_DCS_MASK
# (0x80000), which the driver deliberately leaves off, plus every reserved bit.
# Re-derive from amd_shared.h if a kernel bump changes the default.
#
# NOTE: bootc applies kargs.d on `bootc install`/`switch`/upgrade. If the very
# first `rpm-ostree rebase` onto this image does not pick it up, apply once with
# `rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff`; image-managed
# updates keep it thereafter.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/10-amdgpu.toml << 'EOF'
kargs = ["amdgpu.ppfeaturemask=0xfff7ffff"]
match-architectures = ["x86_64"]
EOF

### 3. LACT — Linux AMDGPU Control Tool (power caps, fan curves, monitoring)
# Uses the powerplay controls unlocked above. Installed from the maintainer's
# COPR, key fingerprint-pinned like the other third-party sources.
add_copr ilyaz-lact ilyaz/LACT DC70DFEA1822B0720140518FA3BA601174A6903B

install_pkgs lact

# Enable the daemon (GUI `lact` talks to it). Clock/voltage offsets need the
# ppfeaturemask karg above; power caps don't. Fan curves are unavailable on the
# R9700 regardless — an amdgpu SMU interface bug, see notes/.
systemctl enable lactd.service
