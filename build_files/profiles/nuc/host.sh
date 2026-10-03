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
