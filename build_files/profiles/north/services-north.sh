#!/bin/bash
set -ouex pipefail

# north-only service enablement (shared services are handled by services.sh).

### Sunshine streaming host
# Sunshine ships a systemd *user* unit; enable it globally so it starts for the
# logged-in user. sunshine.sh drops in the ExecStartPre that seeds the capture
# settings and the global_prep_cmd that resizes the persistent virtual monitor;
# pairing and wiring the prep commands stay per-user first-login steps (see README).
#
# The virtual display is created on demand by the seeded global_prep_cmd (`ensure`),
# NOT at login — sunshine-virtual-monitor.service is shipped disabled as of
# 2026-08-18 because krfb holds a render node and pinned a GPU awake full time. See
# sunshine.sh. ExecStopPost runs `ensure` to restore physical outputs if the last
# stream was exclusive; it does not teardown.
# A crash mid-stream is handled by systemd's user session cleanup.
#
# Use the canonical unit name. pvermeer's package also ships a sunshine.service
# compat symlink, but upstream only declares it as an [Install] Alias= — which
# doesn't exist until the real unit is enabled, so enabling the alias fails.
systemctl --global enable app-dev.lizardbyte.app.Sunshine.service

### SELinux boolean for containerized GPU compute
# Enabled even though the lemonade Quadlet is deliberately not — without it, ROCm dies
# with an HSA abort that looks nothing like a permission error. Guarded and idempotent,
# so it's a no-op on every boot after the first. See lemonade.sh.
systemctl enable lemonade-selinux.service
