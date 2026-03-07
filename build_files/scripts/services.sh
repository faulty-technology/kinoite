#!/bin/bash
set -ouex pipefail

### Override bootc update service to stage only, no auto-reboot
mkdir -p /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d
cat > /usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/stage-only.conf <<'DROPIN'
[Service]
ExecStart=
ExecStart=/usr/bin/bootc upgrade --quiet
DROPIN

### Enable systemd units
systemctl enable podman.socket
systemctl enable bootc-fetch-apply-updates.timer
