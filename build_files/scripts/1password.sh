#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Add 1Password repository
verify_and_import_key "1password" "1Password" \
    "https://downloads.1password.com/linux/keys/1password.asc" \
    3FEF9748469ADBE15DA7CA80AC2D62742012EA22

register_repo_file /etc/yum.repos.d/1password.repo
cat > /etc/yum.repos.d/1password.repo << 'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-1password
EOF

### Install
# 8.12.28+ %post runs `mkdir -p /usr/local/bin` for the MCP server symlink.
# /usr/local is a dangling symlink to ../var/usrlocal during the container
# build, which makes mkdir -p fail — create the target so it resolves.
mkdir -p /var/usrlocal
install_pkgs 1password

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

# GIDs for the onepassword groups. Must be > 1000 to avoid conflicts with real
# user groups. Matches the ublue-os convention.
GID_ONEPASSWORD=1500
GID_ONEPASSWORD_MCP=1501

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

# MCP server (added in 8.12.28): same SO_PEERCRED verification scheme as
# BrowserSupport, with its own group. %post symlinks it into /usr/local/bin,
# which is machine-local state — recreate the symlink in /usr/bin instead and
# drop the /var/usrlocal content so /var stays pristine in the image.
if [ -f /usr/lib/1Password/1password-mcp ]; then
    chgrp "${GID_ONEPASSWORD_MCP}" /usr/lib/1Password/1password-mcp
    chmod g+s /usr/lib/1Password/1password-mcp
    ln -sf /usr/lib/1Password/1password-mcp /usr/bin/1password-mcp
fi
rm -rf /var/usrlocal

# Ensure onepassword groups are created at boot via systemd-sysusers.
# The groups won't survive the ostree /etc merge, so this is essential.
cat > /usr/lib/sysusers.d/onepassword.conf << EOF
g onepassword ${GID_ONEPASSWORD}
g onepassword-mcp ${GID_ONEPASSWORD_MCP}
EOF

# Remove RPM-generated sysusers.d entries that would conflict with our GIDs.
rm -f /usr/lib/sysusers.d/30-rpmostree-pkg-group-onepassword.conf \
    /usr/lib/sysusers.d/30-rpmostree-pkg-group-onepassword-mcp.conf

# Polkit rule: allow any active local user to authenticate for 1Password actions.
cat > /etc/polkit-1/rules.d/10-1password.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("com.1password.1Password.") === 0 &&
            subject.active && subject.local) {
        return polkit.Result.AUTH_SELF;
    }
});
EOF
