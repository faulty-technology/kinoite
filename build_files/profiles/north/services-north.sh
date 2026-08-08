#!/bin/bash
set -ouex pipefail

# north-only service enablement (shared services are handled by services.sh).

### Sunshine streaming host
# Sunshine ships a systemd *user* unit; enable it globally so it starts for the
# logged-in user. Pairing and the kwin capture setting are per-user first-login
# steps (see sunshine.sh / README).
#
# Must use the real filename: `sunshine.service` is only an [Install] Alias=,
# which doesn't exist until the real unit is enabled — enabling the alias fails.
systemctl --global enable app-dev.lizardbyte.app.Sunshine.service
