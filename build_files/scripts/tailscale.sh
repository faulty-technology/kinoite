#!/bin/bash
set -ouex pipefail

### Add Tailscale repository
dnf5 config-manager addrepo \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo

### Install
dnf5 install -y tailscale
echo "tailscale" >> /usr/share/kinoite/packages

### Enable service
systemctl enable tailscaled
