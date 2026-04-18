#!/bin/bash
set -ouex pipefail

### Add 1Password repository
# Fetch the signing key and verify its fingerprint before trusting it.
# If this pin fails, 1Password has rotated their key — verify the new
# fingerprint against their docs and update below in a PR.
KEY_URL="https://downloads.1password.com/linux/keys/1password.asc"
EXPECTED=$(sort <<'EOF'
3FEF9748469ADBE15DA7CA80AC2D62742012EA22
EOF
)
curl -fsSL "$KEY_URL" -o /tmp/1password.asc
ACTUAL=$(gpg --show-keys --with-colons /tmp/1password.asc 2>/dev/null | awk -F: '/^fpr:/ {print $10}' | sort)
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "1Password GPG fingerprint mismatch"
    echo "Expected: $EXPECTED"
    echo "Actual:   $ACTUAL"
    exit 1
fi
rpm --import /tmp/1password.asc
rm -f /tmp/1password.asc

cat > /etc/yum.repos.d/1password.repo << 'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

### Install
dnf5 install -y 1password
echo "1password" >> /usr/share/kinoite/packages

### Fix 1Password for immutable image builds
# Based on ublue-os/BlueBuild approach.
# https://universal-blue.discourse.group/t/fix-faq-1password-browser-extension-and-cli-don-t-work-in-my-custom-image/187
#
# 1) SETGID: The 1Password app verifies BrowserSupport connections via Unix
#    socket peer credentials (SO_PEERCRED). The binary needs setgid to the
#    "onepassword" group so the app trusts it. On composefs (where /opt lives),
#    setgid bits in metadata may not be applied at exec time. Moving the binary
#    to /usr/lib puts it on the ostree-managed filesystem where setgid works.
#
# 2) POLKIT: after-install.sh generates the polkit policy from /etc/passwd,
#    but no real users (UID >= 1000) exist during the container build, leaving
#    org.freedesktop.policykit.owner empty. A polkit rule restores fingerprint
#    and browser auto-unlock for any active local user.

# GID for the onepassword group. Must be > 1000 to avoid conflicts with real
# user groups. Matches the ublue-os convention.
GID_ONEPASSWORD=1500

# Relocate 1Password from /opt (composefs) to /usr/lib (ostree-managed).
# This ensures the setgid bit is properly applied at exec time.
mv /opt/1Password /usr/lib/1Password
ln -sf /usr/lib/1Password /opt/1Password
rm -f /usr/bin/1password
ln -s /usr/lib/1Password/1password /usr/bin/1password

# chrome-sandbox requires setuid
chmod 4755 /usr/lib/1Password/chrome-sandbox

# BrowserSupport setgid — no extra permissions, only anti-tamper hardening.
# Using the GID directly since the group is created via sysusers.d at boot.
chgrp "${GID_ONEPASSWORD}" /usr/lib/1Password/1Password-BrowserSupport
chmod g+s /usr/lib/1Password/1Password-BrowserSupport

# Ensure onepassword group is created at boot via systemd-sysusers.
# The group won't survive the ostree /etc merge, so this is essential.
cat > /usr/lib/sysusers.d/onepassword.conf << EOF
g onepassword ${GID_ONEPASSWORD}
EOF

# Remove RPM-generated sysusers.d entries that would conflict with our GID.
rm -f /usr/lib/sysusers.d/30-rpmostree-pkg-group-onepassword.conf

# Polkit rule: allow any active local user to authenticate for 1Password actions.
cat > /etc/polkit-1/rules.d/10-1password.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("com.1password.1Password.") === 0 &&
            subject.active && subject.local) {
        return polkit.Result.AUTH_SELF;
    }
});
EOF
