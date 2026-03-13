#!/bin/bash
set -ouex pipefail

### 1. Configure rpm-ostreed for Discover/Plasma update notifications
cat > /etc/rpm-ostreed.conf <<'CONF'
[Daemon]
AutomaticUpdatePolicy=stage
CONF

### 2. Use bootc for actual update fetching/staging (bootc owns the deployment)
# Override the default timer to check every 4 hours with persistence across sleep.
mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.timer.d
cat > /etc/systemd/system/bootc-fetch-apply-updates.timer.d/override.conf <<'EOF'
[Timer]
OnBootSec=
OnUnitInactiveSec=
OnCalendar=00/4:00:00
Persistent=true
EOF

# Override the service: stage only (no --apply auto-reboot), wait for DNS, retry on failure.
mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
cat > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=
ExecStartPre=/bin/bash -c 'for i in $(seq 1 15); do getent hosts ghcr.io >/dev/null 2>&1 && exit 0; sleep 2; done'
ExecStart=/usr/bin/bootc upgrade --quiet
Restart=on-failure
RestartSec=30s
EOF

### 3. Disable rpm-ostree automatic updates (can't stage when bootc owns the deployment)
systemctl mask rpm-ostreed-automatic.timer

### 4. Enable bootc update timer and other services
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable podman.socket
