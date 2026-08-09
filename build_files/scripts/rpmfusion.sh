#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Install RPM Fusion (enables free + nonfree repos)
dnf5 install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

record_pkgs rpmfusion-free-release rpmfusion-nonfree-release
