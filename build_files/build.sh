#!/bin/bash

set -ouex pipefail

### Add third-party repositories

# 1Password
rpm --import https://downloads.1password.com/linux/keys/1password.asc
cat > /etc/yum.repos.d/1password.repo << 'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

# Google Chrome
rpm --import https://dl.google.com/linux/linux_signing_key.pub
cat > /etc/yum.repos.d/google-chrome.repo << 'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF

# Tailscale (Fedora stable)
dnf5 config-manager addrepo \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo

### Install RPM Fusion (enables free + nonfree repos)
dnf5 install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

### Install all packages
dnf5 install -y \
    1password \
    distrobox \
    google-chrome-stable \
    intel-media-driver \
    lm_sensors \
    podman-compose \
    powertop \
    tailscale

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

### Enable systemd units
systemctl enable tailscaled
systemctl enable podman.socket
systemctl enable bootc-fetch-apply-updates.timer

### Configure container signature policy for bootc update verification
mkdir -p /etc/pki/containers
cp /ctx/cosign.pub /etc/pki/containers/faulty-technology-kinoite.pub

cat > /etc/containers/policy.json << 'EOF'
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "ghcr.io/faulty-technology/kinoite": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/pki/containers/faulty-technology-kinoite.pub",
          "signedIdentity": {"type": "matchRepository"}
        }
      ],
      "": [{"type": "insecureAcceptAnything"}]
    },
    "docker-daemon": {"": [{"type": "insecureAcceptAnything"}]},
    "oci": {"": [{"type": "insecureAcceptAnything"}]},
    "oci-archive": {"": [{"type": "insecureAcceptAnything"}]},
    "containers-storage": {"": [{"type": "insecureAcceptAnything"}]}
  }
}
EOF

# Tell containers/image to look for cosign signatures stored as OCI artifacts
# in the same registry (the default without this is an old-style lookaside server)
cat > /etc/containers/registries.d/ghcr.io-faulty-technology-kinoite.yaml << 'EOF'
docker:
  ghcr.io/faulty-technology/kinoite:
    use-sigstore-attachments: true
EOF

### Remove third-party repo files — updates come from CI rebuilds, not live dnf
rm -f \
    /etc/yum.repos.d/1password.repo \
    /etc/yum.repos.d/google-chrome.repo \
    /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:phracek:PyCharm.repo \
    /etc/yum.repos.d/tailscale.repo
