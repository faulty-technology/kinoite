#!/bin/bash
set -ouex pipefail

### Add Google Chrome repository
# Google's keyring bundles historical signing keys. Pin all current
# fingerprints — if Google adds or rotates a key, CI will fail loudly
# and the new fingerprint must be reviewed and added in a PR.
KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
EXPECTED=$(sort <<'EOF'
EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
3B068FB4789ABE4AEFA3BB491397BC53640DB551
3E50F6D3EC278FDEB655C8CA6494C6D6997C215E
2F528D36D67B69EDF998D85778BD65473CB3BD13
8461EFA0E74ABAE010DE66994EB27DB2A3B88B8B
A5F483CD733A4EBAEA378B2AE88979FB9B30ACF2
0F06FF86BEEAF4E71866EE5232EE5355A6BC6E42
0E225917414670F4442C250DFD533C07C264648F
EOF
)
curl -fsSL "$KEY_URL" -o /tmp/google.asc
ACTUAL=$(gpg --show-keys --with-colons /tmp/google.asc 2>/dev/null | awk -F: '/^fpr:/ {print $10}' | sort)
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "Google Chrome GPG fingerprint mismatch"
    echo "Expected:"; echo "$EXPECTED"
    echo "Actual:";   echo "$ACTUAL"
    exit 1
fi
rpm --import /tmp/google.asc
rm -f /tmp/google.asc

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
