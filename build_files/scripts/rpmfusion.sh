#!/bin/bash
set -ouex pipefail

### Install RPM Fusion (enables free + nonfree repos)
dnf5 install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

echo "rpmfusion-free-release" >> /usr/share/kinoite/packages
echo "rpmfusion-nonfree-release" >> /usr/share/kinoite/packages
