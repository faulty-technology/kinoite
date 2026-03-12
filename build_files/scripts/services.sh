#!/bin/bash
set -ouex pipefail

### 1. Configure rpm-ostreed to stage updates
# This ensures Discover/Plasma notifies you instead of bootc auto-rebooting.
cat > /etc/rpm-ostreed.conf <<'CONF'
[Daemon]
AutomaticUpdatePolicy=stage
CONF

### 2. Add the Calendar Timer Override
# This ensures checks happen every 4 hours and resume after sleep.
mkdir -p /etc/systemd/system/rpm-ostreed-automatic.timer.d
cat > /etc/systemd/system/rpm-ostreed-automatic.timer.d/override.conf <<'EOF'
[Timer]
OnBootSec=
OnUnitInactiveSec=
OnCalendar=00/4:00:00
Persistent=true
EOF

# 3. Service Override: Retry on network failures (the dial ghcr.io error)
mkdir -p /etc/systemd/system/rpm-ostreed-automatic.service.d
cat > /etc/systemd/system/rpm-ostreed-automatic.service.d/override.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=30s
EOF

### 4. Manage Systemd Units
# Use 'enable' only (remove '--now') since systemd isn't running during build.
systemctl mask bootc-fetch-apply-updates.timer
systemctl enable rpm-ostreed-automatic.timer


systemctl enable podman.socket
