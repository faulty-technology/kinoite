#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Full multimedia codec stack (RPM Fusion)
# Fedora builds ffmpeg with the patent-encumbered codecs compiled out, and ships
# no mesa VA-API driver at all — mesa-va-drivers/mesa-vdpau-drivers don't exist
# in Fedora 44. So a stock install has no H.264/HEVC playback and no hardware
# encoder whatsoever, which is why Sunshine reports "no h264".
#
# ffmpeg Conflicts ffmpeg-free, so it needs --allowerasing to displace it.
# mesa-va-drivers-freeworld has no Fedora counterpart, so it plainly installs
# (and it obsoletes mesa-vdpau-drivers-freeworld, covering VDPAU too).
install_pkgs_erasing ffmpeg
install_pkgs mesa-va-drivers-freeworld gstreamer1-plugins-bad-freeworld

# Deliberately NOT swapping mesa-vulkan-drivers for the freeworld build — but note the
# reason has changed. It used to be a version argument (RPM Fusion trailed Fedora, and
# downgrading the Vulkan driver on RDNA4 cost more than the VK_hdr_layer it brought).
# That gap has closed: RPM Fusion's -updates now carries mesa-vulkan-drivers-freeworld
# at the same version Fedora ships. So this is now purely "nothing here needs HDR yet".
# Swap it if gamescope HDR becomes wanted, after re-checking the versions still match:
#   dnf repoquery mesa-vulkan-drivers-freeworld && rpm -q mesa-vulkan-drivers

