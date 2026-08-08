#!/bin/bash
set -ouex pipefail

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

### GPU firmware (amdgpu microcode; subpackage of linux-firmware)
PACKAGES=(
    amd-gpu-firmware
    mesa-vulkan-drivers
)
dnf5 install -y "${PACKAGES[@]}"
printf '%s\n' "${PACKAGES[@]}" >> /usr/share/kinoite/packages

### Compute device access for containerized ROCm
# ROCm ships no host packages here, so /dev/kfd would be root-only. Bake the
# standard ROCm udev rule so the compute (/dev/kfd) and render (/dev/dri/renderD*)
# nodes are owned by the `render` group. The `render` and `video` groups already
# exist in the base image; the login user must still be added to them — that is
# machine-local state and cannot ship in the image, so it is a documented
# post-rebase step (`usermod -aG render,video <user>`; see README).
cat > /usr/lib/udev/rules.d/70-kfd.rules << 'EOF'
# AMD KFD (ROCm compute) — grant the render group access to the compute node.
KERNEL=="kfd", GROUP="render", MODE="0660"
# DRM render nodes for GPU compute/offload.
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"
EOF
