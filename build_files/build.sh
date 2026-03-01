#!/bin/bash

set -ouex pipefail

### Add third-party repositories

# 1Password
rpm --import https://downloads.1password.com/linux/keys/1password.asc
cat > /etc/yum.repos.d/1password.repo << 'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

# Google Chrome
rpm --import https://dl.google.com/linux/linux_signing_key.pub
cat > /etc/yum.repos.d/google-chrome.repo << 'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF

# Tailscale (Fedora stable)
dnf5 config-manager addrepo \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo

### Install RPM Fusion (enables free + nonfree repos)
dnf5 install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

### Install all packages
dnf5 install -y \
    1password \
    distrobox \
    google-chrome-stable \
    intel-media-driver \
    lm_sensors \
    podman-compose \
    powertop \
    tailscale

### Enable systemd units
systemctl enable tailscaled
systemctl enable podman.socket

### Remove third-party repo files — updates come from CI rebuilds, not live dnf
rm -f \
    /etc/yum.repos.d/1password.repo \
    /etc/yum.repos.d/google-chrome.repo \
    /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:phracek:PyCharm.repo \
    /etc/yum.repos.d/tailscale.repo
