#!/bin/bash
set -ouex pipefail

# north-only service enablement (shared services are handled by services.sh).

### Sunshine streaming host
# Sunshine ships a systemd *user* unit; enable it globally so it starts for the
# logged-in user. sunshine.sh drops in the ExecStartPre that seeds the capture
# settings and the ExecStopPost that tears the virtual monitor down; pairing and
# wiring the prep commands stay per-user first-login steps (see README).
#
# Use the canonical unit name. pvermeer's package also ships a sunshine.service
# compat symlink, but upstream only declares it as an [Install] Alias= — which
# doesn't exist until the real unit is enabled, so enabling the alias fails.
systemctl --global enable app-dev.lizardbyte.app.Sunshine.service
