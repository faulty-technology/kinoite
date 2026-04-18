#!/bin/bash
set -ouex pipefail

### Add Tailscale repository
# Fetch and verify the signing key before trusting it, then write the
# repo file inline so we don't blindly trust the remote .repo either.
KEY_URL="https://pkgs.tailscale.com/stable/fedora/repo.gpg"
EXPECTED=$(sort <<'EOF'
2596A99EAAB33821893C0A79458CA832957F5868
2F625B3A774B946822EDDBEEB1547A3DDAAF03C6
EOF
)
curl -fsSL "$KEY_URL" -o /tmp/tailscale.asc
ACTUAL=$(gpg --show-keys --with-colons /tmp/tailscale.asc 2>/dev/null | awk -F: '/^fpr:/ {print $10}' | sort)
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "Tailscale GPG fingerprint mismatch"
    echo "Expected:"; echo "$EXPECTED"
    echo "Actual:";   echo "$ACTUAL"
    exit 1
fi
rpm --import /tmp/tailscale.asc
rm -f /tmp/tailscale.asc

cat > /etc/yum.repos.d/tailscale.repo << 'EOF'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/fedora/repo.gpg
EOF

### Install
dnf5 install -y tailscale
echo "tailscale" >> /usr/share/kinoite/packages

### Enable service
systemctl enable tailscaled
