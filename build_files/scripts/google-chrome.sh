#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/verify-key.sh"

### Add Google Chrome repository
# Google's keyring bundles historical signing keys — pin all of them so a
# rotation or added key fails CI until a human reviews the new fingerprint.
verify_and_import_key "Google Chrome" \
    "https://dl.google.com/linux/linux_signing_key.pub" \
    EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796 \
    3B068FB4789ABE4AEFA3BB491397BC53640DB551 \
    3E50F6D3EC278FDEB655C8CA6494C6D6997C215E \
    2F528D36D67B69EDF998D85778BD65473CB3BD13 \
    8461EFA0E74ABAE010DE66994EB27DB2A3B88B8B \
    A5F483CD733A4EBAEA378B2AE88979FB9B30ACF2 \
    0F06FF86BEEAF4E71866EE5232EE5355A6BC6E42 \
    0E225917414670F4442C250DFD533C07C264648F

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
