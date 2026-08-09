#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# AMD RDNA4 / Radeon AI PRO R9700 (gfx1201) enablement.
#
# Host stays lean: NO host ROCm packages — ROCm 7.2+ (required for gfx1201)
# lives in containers so it tracks independently of Fedora 44 (see llm.sh).
# This script only ensures the amdgpu firmware is present and that the compute
# device nodes are reachable by an unprivileged, containerized ROCm runtime.
#
# TODO(hardware): confirm Fedora 44's kernel + linux-firmware + mesa are new
# enough to drive the R9700 (RDNA4/gfx1201) and enumerate both GPUs. Fallback:
# newer-kernel COPR or a linux-firmware override. See notes/kinoite-north-validation.md.

### GPU firmware (amdgpu microcode; subpackage of linux-firmware) + monitoring
# VAAPI/Vulkan drivers are not listed here — the shared codecs.sh swaps in the
# freeworld mesa builds, and gaming.sh handles the 32-bit half for Proton.
install_pkgs amd-gpu-firmware amdsmi

### Compute device access for containerized ROCm
# Only /dev/kfd needs a rule — systemd's 70-uaccess.rules already tags the DRM
# render nodes, so logind ACLs those to the active seat user. uaccess grants
# nothing without an active seat, so GROUP="render" stays as the headless path.
#
# TODO(hardware): confirm uaccess lands on /dev/kfd — it's a non-DRM device, so
# seat assignment is the open question. See notes/kinoite-north-validation.md.
cat > /usr/lib/udev/rules.d/70-kfd.rules << 'EOF'
KERNEL=="kfd", TAG+="uaccess", GROUP="render", MODE="0660"
EOF
