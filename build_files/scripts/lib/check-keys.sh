#!/bin/bash
# Quick check: fetch live vendor GPG fingerprints and print them alongside
# what's pinned in each script. Eyeball the diff, update the scripts if needed.
#
# Usage: ./build_files/scripts/lib/check-keys.sh

set -euo pipefail

echo "=== Google Chrome ==="
echo "Live fingerprints:"
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --show-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/ {print "  " $10}'

echo
echo "=== 1Password ==="
echo "Live fingerprints:"
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --show-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/ {print "  " $10}'

echo
echo "=== Tailscale ==="
echo "Live fingerprints:"
curl -fsSL https://pkgs.tailscale.com/stable/fedora/repo.gpg \
    | gpg --show-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/ {print "  " $10}'
