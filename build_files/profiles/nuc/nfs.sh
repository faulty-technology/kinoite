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

### Wait for Unraid's NFS port
# Holds the mounts until ${UNRAID_HOST}:2049 accepts a TCP connection, for up to 90 s, then exits
# either way. Evidence: docs/runs/2026-11-14-nuc-nfs-boot-race.md
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-nfs-wait << 'SCRIPT'
#!/bin/bash
# usage: kinoite-nfs-wait <host> <port> <seconds>
set -uo pipefail
host="$1" port="$2" limit="$3"
start=$SECONDS
while (( SECONDS - start < limit )); do
    if timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        echo "$host:$port reachable after $(( SECONDS - start ))s"
        exit 0
    fi
    sleep 2
done
echo "$host:$port not reachable after ${limit}s; mounting anyway" >&2
exit 1
SCRIPT
bash -n /usr/libexec/kinoite-nfs-wait

cat > /usr/lib/systemd/system/kinoite-nfs-wait.service << UNIT
[Unit]
Description=Wait for Unraid NFS (${UNRAID_HOST}:2049)
Wants=network-online.target tailscale-online.target
After=network-online.target tailscale-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/kinoite-nfs-wait ${UNRAID_HOST} 2049 90
TimeoutStartSec=120
UNIT

# Static mounts, not automounts: an autofs trigger bind-mounted into a container
# does not follow the real mount that lands on it later.
# hard: an Unraid hiccup stalls I/O rather than handing apps EIO mid-write.
# $3 = mount options; defaults to the rw set. Media is mounted ro (k3s and
# direct use are read-only); fast/appdata stays rw for podman.
write_mount() {
    local what="$1" where="$2" opts="${3:-nfsvers=4.2,hard,noatime,_netdev}" unit
    unit="$(systemd-escape --path --suffix=mount "$where")"
    cat > "/usr/lib/systemd/system/${unit}" << UNIT
[Unit]
Description=Unraid NFS ${where}
# tailscale-online.target (shipped by the tailscale package) runs 'tailscale wait':
# tailscaled.service alone reports ready before the interface has its IP.
# kinoite-nfs-wait: tailscale-online.target can be reached before the path to Unraid carries
# traffic. Wants=, not Requires=, so a NAS that never answers still gets a mount attempt.
Wants=network-online.target tailscale-online.target kinoite-nfs-wait.service
After=network-online.target tailscale-online.target kinoite-nfs-wait.service

[Mount]
What=${UNRAID_HOST}:${what}
Where=${where}
Type=nfs
Options=${opts}
TimeoutSec=30

[Install]
WantedBy=remote-fs.target
UNIT
    echo "$unit" >> /usr/share/kinoite/nfs-units
}

# media (arrdata) is read-only for k3s and direct use; fast (appdata) stays rw.
write_mount "$MEDIA_EXPORT" /var/mnt/unraid/media "nfsvers=4.2,hard,noatime,ro,_netdev"
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
