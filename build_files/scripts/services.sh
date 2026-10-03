#!/bin/bash
set -ouex pipefail

### 1. Configure rpm-ostreed for Discover/Plasma update notifications
cat > /etc/rpm-ostreed.conf <<'CONF'
[Daemon]
AutomaticUpdatePolicy=stage
CONF

### 2. Use bootc for actual update fetching/staging (bootc owns the deployment)
# UPDATE_POLICY is exported by the profile orchestrator:
#   stage (default) — check every 4 hours, stage the update, apply on the next manual reboot.
#   apply           — check weekly and reboot into the update (headless servers that never
#                     reboot on their own).
case "${UPDATE_POLICY:-stage}" in
    stage)
        UPDATE_CALENDAR='00/4:00:00'
        UPDATE_CMD='/usr/bin/bootc upgrade --quiet'
        UPDATE_JITTER='2h'
        ;;
    apply)
        # No jitter: the stock 2h random delay would turn the reboot window into 04:00–06:00.
        UPDATE_CALENDAR='Sun *-*-* 04:00:00'
        UPDATE_CMD='/usr/bin/bootc upgrade --apply --quiet'
        UPDATE_JITTER='0'
        ;;
    *)
        echo "services.sh: unknown UPDATE_POLICY '${UPDATE_POLICY}'" >&2
        exit 1
        ;;
esac

# Override the default timer; Persistent= catches up on a check missed while powered off.
mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.timer.d
cat > /etc/systemd/system/bootc-fetch-apply-updates.timer.d/override.conf <<EOF
[Timer]
OnBootSec=
OnUnitInactiveSec=
OnCalendar=${UPDATE_CALENDAR}
RandomizedDelaySec=${UPDATE_JITTER}
Persistent=true
EOF

# Override the service: wait for DNS, retry on failure.
mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
cat > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 15); do getent hosts ghcr.io >/dev/null 2>&1 && exit 0; sleep 2; done'
ExecStart=${UPDATE_CMD}
Restart=on-failure
RestartSec=30s
EOF

### 3. Disable rpm-ostree automatic updates (can't stage when bootc owns the deployment)
systemctl mask rpm-ostreed-automatic.timer

### 4. Enable bootc update timer and other services
systemctl enable bootc-fetch-apply-updates.timer
systemctl enable podman.socket

### 5. Mask systemd-remount-fs.service — it cannot succeed on a composefs root
# systemd-fstab-generator pulls this unit in because /etc/fstab has a `/` entry, but `/` is a
# composefs overlay and the kernel refuses to reconfigure an overlay mount, so every boot ends:
#     mount: /: fsconfig() failed: overlay: No changes allowed in reconfigure.
# Upstream's fix is to comment the `/` line out of /etc/fstab, but fstab is anaconda-created
# machine state the image does not ship (there is no /usr/etc/fstab), so the image cannot manage
# it. Masking is the declarative equivalent and survives a reinstall. Root mount options come
# from the rootflags= karg rather than fstab — see the btrfs compression note in the README.
# Refs: fedora-silverblue/issue-tracker#605, ostreedev/ostree#3193, RHBZ 2348934.
systemctl mask systemd-remount-fs.service
