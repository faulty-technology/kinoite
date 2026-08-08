#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/verify-key.sh"

# AMD 9900X (Zen 5) + dual R9700 (RDNA4) tunings for a gaming + local-LLM box.

### 1. vm.max_map_count
# Fedora's default (1048576) is fine for most workloads, but the SteamOS value
# fixes a class of Proton games that hang/crash on the lower limit and also helps
# memory-mapped model loading in LLM runtimes (large mmap counts). No downside.
cat > /usr/lib/sysctl.d/99-north.conf << 'EOF'
vm.max_map_count=2147483642
EOF

### 2. amdgpu powerplay controls (baked kernel arg)
# Unlocks the full powerplay table so power limits, clocks, and fan curves are
# adjustable (e.g. via LACT below). This only *exposes* the controls — no
# behavior change on its own. Baked declaratively via bootc kargs.d instead of a
# manual `rpm-ostree kargs --append`.
#
# NOTE: bootc applies kargs.d on `bootc install`/`switch`/upgrade. If the very
# first `rpm-ostree rebase` onto this image does not pick it up, apply once with
# `rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xffffffff`; image-managed
# updates keep it thereafter.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/10-amdgpu.toml << 'EOF'
kargs = ["amdgpu.ppfeaturemask=0xffffffff"]
match-architectures = ["x86_64"]
EOF

### 3. LACT — Linux AMDGPU Control Tool (power caps, fan curves, monitoring)
# Uses the powerplay controls unlocked above. Installed from the maintainer's
# COPR, key fingerprint-pinned like the other third-party sources.
verify_and_import_key "ilyaz-lact" "LACT COPR (ilyaz)" \
    "https://download.copr.fedorainfracloud.org/results/ilyaz/LACT/pubkey.gpg" \
    DC70DFEA1822B0720140518FA3BA601174A6903B

cat > /etc/yum.repos.d/_copr_ilyaz-LACT.repo << 'EOF'
[copr:copr.fedorainfracloud.org:ilyaz:LACT]
name=Copr repo for LACT owned by ilyaz
baseurl=https://download.copr.fedorainfracloud.org/results/ilyaz/LACT/fedora-$releasever-$basearch/
type=rpm-md
skip_if_unavailable=False
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ilyaz-lact
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF

dnf5 install -y lact
echo "lact" >> /usr/share/kinoite/packages

# Enable the daemon (GUI `lact` talks to it). Fan/power editing needs the
# ppfeaturemask karg above to be active.
systemctl enable lactd.service
