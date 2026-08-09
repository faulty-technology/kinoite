#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Add Tailscale repository
# Write the repo file inline so we don't blindly trust the remote .repo either.
verify_and_import_key "tailscale" "Tailscale" \
    "https://pkgs.tailscale.com/stable/fedora/repo.gpg" \
    2596A99EAAB33821893C0A79458CA832957F5868 \
    2F625B3A774B946822EDDBEEB1547A3DDAAF03C6

register_repo_file /etc/yum.repos.d/tailscale.repo
cat > /etc/yum.repos.d/tailscale.repo << 'EOF'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale
EOF

### Install
install_pkgs tailscale

### Enable service
systemctl enable tailscaled
