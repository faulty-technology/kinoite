#!/bin/bash
set -ouex pipefail

### Add Google Chrome repository
rpm --import https://dl.google.com/linux/linux_signing_key.pub
cat > /etc/yum.repos.d/google-chrome.repo << 'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF

### Install
dnf5 install -y google-chrome-stable
echo "google-chrome-stable" >> /usr/share/kinoite/packages

### Chrome fixes
# 1. PWA FIX: Hardcode CHROME_WRAPPER so Chrome doesn't use readlink -f, which
#    follows /opt -> /usr/lib/opt at deploy time and writes the wrong path into
#    PWA .desktop Exec= lines causing KDE to fail launching them.
# 2. TOUCHPAD NAVIGATION: Inject flag via set -- so it applies to every Chrome
#    invocation (main browser and all PWAs) regardless of which is opened first.
sed -i \
    -e 's|CHROME_WRAPPER="`readlink -f "$0"`"|CHROME_WRAPPER="/opt/google/chrome/google-chrome"|' \
    -e '/^HERE=/a set -- --enable-features=TouchpadOverscrollHistoryNavigation "$@"' \
    /opt/google/chrome/google-chrome
