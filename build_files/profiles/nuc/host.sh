#!/bin/bash
set -ouex pipefail

### inotify limits
# Fedora's defaults (128 instances) run out with k3s plus the library watchers in
# Plex and the *arr apps, and the failure shows up as apps silently missing new files.
cat > /usr/lib/sysctl.d/60-nuc.conf << 'EOF2'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF2

### Never sleep
# A 24/7 server. Nothing on a headless install should ask for sleep, but a stray
# logind/key event must not take the cluster down either.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

### Install-time root filesystem
# fedora-bootc declares no default, so bootc-image-builder and `bootc install`
# refuse to run without one. xfs: Fedora Server's default, and no rootflags=
# compression karg to manage as on the btrfs desktops.
mkdir -p /usr/lib/bootc/install
cat > /usr/lib/bootc/install/00-nuc.toml << 'EOF2'
[install.filesystem.root]
type = "xfs"
EOF2
