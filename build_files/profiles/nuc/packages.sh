#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### Already in fedora-bootc — asserted, not installed
# Not recorded in the manifest: the SBOM is additive, and these come from the base.
# linux-firmware carries the i915 GuC/HuC blobs QuickSync needs on Alder Lake;
# container-selinux is what k3s-selinux builds on.
rpm -q linux-firmware nfs-utils container-selinux iptables-nft

### Install standard Fedora packages
# igt-gpu-tools (formerly intel-gpu-tools) for intel_gpu_top (is a transcode actually on the GPU?);
# distrobox for one-off host tooling, since the host has no dnf at runtime.
install_pkgs \
    distrobox \
    igt-gpu-tools \
    lm_sensors \
    smartmontools
