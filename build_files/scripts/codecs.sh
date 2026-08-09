#!/bin/bash
set -ouex pipefail

### Full multimedia codec stack (RPM Fusion)
# Fedora builds ffmpeg with the patent-encumbered codecs compiled out, and ships
# no mesa VA-API driver at all — mesa-va-drivers/mesa-vdpau-drivers don't exist
# in Fedora 44. So a stock install has no H.264/HEVC playback and no hardware
# encoder whatsoever, which is why Sunshine reports "no h264".
#
# ffmpeg Conflicts ffmpeg-free, so it needs --allowerasing to displace it.
# mesa-va-drivers-freeworld has no Fedora counterpart, so it plainly installs
# (and it obsoletes mesa-vdpau-drivers-freeworld, covering VDPAU too).
dnf5 install -y --allowerasing ffmpeg
dnf5 install -y mesa-va-drivers-freeworld gstreamer1-plugins-bad-freeworld

# Deliberately NOT swapping mesa-vulkan-drivers for the freeworld build: RPM
# Fusion trails Fedora's mesa (26.0.3 vs 26.1.6), and downgrading the Vulkan
# driver on RDNA4 costs more than the VK_hdr_layer it would bring.

printf '%s\n' \
    ffmpeg \
    mesa-va-drivers-freeworld \
    gstreamer1-plugins-bad-freeworld \
    >> /usr/share/kinoite/packages
