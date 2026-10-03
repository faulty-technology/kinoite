#!/bin/bash
set -ouex pipefail

# Unraid NFS mounts for media (array share) and fast storage (SSD-pool share).
#
# Fill these in to ship the mounts. While UNRAID_HOST is empty no units are written,
# so the image builds and boots without them. Use the LAN address, not the tailnet
# one: media traffic does not need to pay WireGuard overhead on the same L2.
UNRAID_HOST=""
MEDIA_EXPORT=""     # e.g. /mnt/user/media
FAST_EXPORT=""      # e.g. /mnt/user/fast

if [ -z "$UNRAID_HOST" ]; then
    echo "nfs.sh: UNRAID_HOST unset; no NFS mounts baked"
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
Wants=network-online.target
After=network-online.target

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
