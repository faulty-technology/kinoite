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
# Deliberately NO udev rule. systemd-udev's own 50-udev-default.rules already ships
#     SUBSYSTEM=="kfd", GROUP="render", MODE="0666"
# so /dev/kfd is world-accessible out of the box, exactly like the DRM render nodes.
#
# This image used to ship 70-kfd.rules with MODE="0660" + TAG+="uaccess", and that was a
# net LOSS: it TIGHTENED the base 0666, then handed the access back only to the
# active-seat user (via the uaccess ACL) or to members of `render`. The practical cost
# was that a headless SSH session, having no seat, needed `usermod -aG render` for
# something that was never restricted in the first place. Dropping the rule restores 0666
# and removes that fallback. Before re-adding any rule here, check what the base already
# gives you: `stat -c '%a %G' /dev/kfd` and `grep -r kfd /usr/lib/udev/rules.d/`.
#
# (For the record the uaccess tag did work — getfacl on a seated login showed the user
# ACL land on /dev/kfd. It is simply redundant at mode 0666.)
