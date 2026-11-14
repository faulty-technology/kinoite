#!/bin/bash
set -ouex pipefail

# nuc-only service enablement (shared services are handled by services.sh;
# tailscaled is enabled by tailscale.sh).

systemctl enable k3s.service

# iGPU frequency gauges for the node-exporter textfile collector (igpu-metrics.sh).
systemctl enable kinoite-igpu-metrics.timer

# Written by nfs.sh only when the Unraid host is configured.
if [ -s /usr/share/kinoite/nfs-units ]; then
    xargs -r systemctl enable < /usr/share/kinoite/nfs-units
fi
