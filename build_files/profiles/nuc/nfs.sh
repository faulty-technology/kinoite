#!/bin/bash
set -ouex pipefail

# Unraid NFS mounts for media (array share) and fast storage (SSD-pool share).
#
# Mounted over the tailnet. UNRAID_HOST is Unraid's Tailscale IP (100.x), not its
# MagicDNS name, so a mount never waits on DNS at boot. Tailscale ACLs must allow
# this node to reach it on tcp:2049; NFSv4 needs no other port.
#
# Fill these in to ship the mounts. Until all three are set no units are written,
# so the image builds and boots without them.
UNRAID_HOST="100.77.22.80"   # Unraid server "NUCi7" (LAN 192.168.200.46)
MEDIA_EXPORT="/mnt/user/arrdata"   # media array share
FAST_EXPORT="/mnt/user/appdata"    # SSD-pool share

if [ -z "$UNRAID_HOST" ] || [ -z "$MEDIA_EXPORT" ] || [ -z "$FAST_EXPORT" ]; then
    echo "nfs.sh: UNRAID_HOST/MEDIA_EXPORT/FAST_EXPORT not all set; no NFS mounts baked"
    exit 0
fi

# Static mounts, not automounts: an autofs trigger bind-mounted into a container
# does not follow the real mount that lands on it later.
# hard: an Unraid hiccup stalls I/O rather than handing apps EIO mid-write.
write_mount() {
    local what="$1" where="$2" unit
    unit="$(systemd-escape --path --suffix=mount "$where")"
    cat > "/usr/lib/systemd/system/${unit}" << UNIT
[Unit]
Description=Unraid NFS ${where}
# tailscale-online.target (shipped by the tailscale package) runs 'tailscale wait':
# tailscaled.service alone reports ready before the interface has its IP.
Wants=network-online.target tailscale-online.target
After=network-online.target tailscale-online.target

[Mount]
What=${UNRAID_HOST}:${what}
Where=${where}
Type=nfs
Options=nfsvers=4.2,hard,noatime,_netdev
TimeoutSec=30

[Install]
WantedBy=remote-fs.target
UNIT
    echo "$unit" >> /usr/share/kinoite/nfs-units
}

write_mount "$MEDIA_EXPORT" /var/mnt/unraid/media
write_mount "$FAST_EXPORT"  /var/mnt/unraid/fast

### Retry failed mounts
# A mount that times out at boot (NAS unreachable) stays failed; nothing in
# systemd retries it. Every 5 minutes, start any of these units that is in the
# failed state. Units stopped on purpose are inactive, not failed, and are left
# alone; starting an active unit is a no-op anyway.
# Evidence: docs/runs/2026-10-06-nuc-boot-with-nfs-down.md
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-nfs-retry << 'SCRIPT'
#!/bin/bash
set -uo pipefail
while read -r unit; do
    [ -n "$unit" ] || continue
    if systemctl is-failed --quiet "$unit"; then
        echo "retrying $unit"
        systemctl start "$unit" || echo "$unit still failing"
    fi
done < /usr/share/kinoite/nfs-units
exit 0
SCRIPT
bash -n /usr/libexec/kinoite-nfs-retry

cat > /usr/lib/systemd/system/kinoite-nfs-retry.service << 'UNIT'
[Unit]
Description=Retry failed Unraid NFS mounts
After=tailscale-online.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-nfs-retry
UNIT

cat > /usr/lib/systemd/system/kinoite-nfs-retry.timer << 'UNIT'
[Unit]
Description=Retry failed Unraid NFS mounts every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

systemctl enable kinoite-nfs-retry.timer
