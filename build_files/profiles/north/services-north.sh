#!/bin/bash
set -ouex pipefail

# north-only service enablement (shared services are handled by services.sh).

### Sunshine streaming host
# Sunshine ships a systemd *user* unit (it needs the graphical session). Enable
# it globally so it starts for the logged-in user on first boot. Pairing, the
# kwin capture-method setting, and the virtual-display prep commands are per-user
# first-login steps (see sunshine.sh / README).
#
# The unit MUST be referenced by its real filename. Upstream declares
# `Alias=sunshine.service` in [Install], but that alias symlink is only created
# *by* enabling — `systemctl enable` resolves its argument against the unit
# search path first, so `enable sunshine.service` fails with "unit does not
# exist" and takes the build down with it.
systemctl --global enable app-dev.lizardbyte.app.Sunshine.service
