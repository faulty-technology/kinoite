#!/bin/bash
set -ouex pipefail

### Configure rpm-ostreed to automatically stage updates
### Discover (plasma-discover-rpm-ostree) queries rpm-ostreed for update status,
### so letting rpm-ostreed handle staging means Discover will notify when an
### update is staged and ready to reboot into.
cat > /etc/rpm-ostreed.conf <<'CONF'
[Daemon]
AutomaticUpdatePolicy=stage
CONF

### Disable the bootc timer — rpm-ostreed handles update staging now
systemctl disable bootc-fetch-apply-updates.timer

### Enable systemd units
systemctl enable podman.socket
