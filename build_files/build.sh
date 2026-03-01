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

### Enable systemd units
systemctl enable tailscaled
systemctl enable podman.socket

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
    "docker-daemon": [{"type": "insecureAcceptAnything"}],
    "oci": [{"type": "insecureAcceptAnything"}],
    "oci-archive": [{"type": "insecureAcceptAnything"}],
    "containers-storage": [{"type": "insecureAcceptAnything"}]
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
