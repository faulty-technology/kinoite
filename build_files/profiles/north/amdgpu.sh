#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# AMD RDNA4 / Radeon AI PRO R9700 (gfx1201) enablement.
#
# Host stays lean: NO host ROCm packages — ROCm 7.2+ (required for gfx1201)
# lives in containers so it tracks independently of Fedora 44 (see lemonade.sh).
# This script only ensures the amdgpu firmware is present and that the compute
# device nodes are reachable by an unprivileged, containerized ROCm runtime.
#
# Fedora 44's kernel + linux-firmware + mesa drive the R9700 (RDNA4/gfx1201) and enumerate
# both cards at gfx_target_version 120001. If a future base regresses that, the fallback is a
# newer-kernel COPR or a linux-firmware override. See docs/reference/gpu-topology.md.

### GPU firmware (amdgpu microcode; subpackage of linux-firmware) + monitoring
# VAAPI/Vulkan drivers are not listed here — the shared codecs.sh swaps in the
# freeworld mesa builds, and gaming.sh handles the 32-bit half for Proton.
install_pkgs amd-gpu-firmware amdsmi

### Compute device access for containerized ROCm
# Fedora ships /dev/kfd world-accessible (MODE="0666" in 50-udev-default.rules).
# This image used to ship 70-kfd.rules with MODE="0660" + TAG+="uaccess" — a net
# loss: it tightened the base 0666 and handed access back only to the seated user.
# Full story: docs/runs/2026-09-05-build-comment-consolidation.md#prior-udev-rule-removed
