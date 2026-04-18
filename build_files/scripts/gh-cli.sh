#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/verify-key.sh"

### Add GitHub CLI repository
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md
verify_and_import_key "GitHub CLI" \
    "https://cli.github.com/packages/githubcli-archive-keyring.asc" \
    2C6106201985B60E6C7AC87323F3D4EA75716059 \
    5700BAB26C8DE75F3EE323FEE5FAF19590714157 \
    7F38BBB59D064DBCB3D84D725612B36462313325 \
    B84252FAAA164D9EBEA2E2C1F4CAB2C46C97E579

cat > /etc/yum.repos.d/gh-cli.repo << 'EOF'
[gh-cli]
name=packages for the GitHub CLI
baseurl=https://cli.github.com/packages/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://cli.github.com/packages/githubcli-archive-keyring.asc
EOF

### Install
dnf5 install -y gh --repo gh-cli
echo "gh" >> /usr/share/kinoite/packages
