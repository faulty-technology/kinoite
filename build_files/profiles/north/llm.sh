#!/bin/bash
set -ouex pipefail

# Local-LLM enablement (containerized ROCm).
#
# The heavy lifting is intentionally NOT here: ROCm 7.2+ (required for the
# R9700 / gfx1201) and lemonade run inside podman containers so they track
# independently of Fedora 44. The host-side enabling bits are already in place:
#   - podman           (base image)
#   - podman-compose   (north packages.sh)
#   - distrobox        (north packages.sh)
#   - /dev/kfd access via the uaccess udev rule (amdgpu.sh); /dev/dri render
#     nodes are already covered by systemd's own 70-uaccess.rules
#
# TODO(hardware): pick a gfx1201-capable ROCm 7.2+ container image, confirm
# rootless podman can pass through /dev/kfd, then add a lemonade Quadlet
# `.container` unit here and enable it from services-north.sh. Kept as a
# documentation-only no-op until then so the image ships nothing half-wired.
# See notes/kinoite-north-validation.md.

# Sanity check the enabling bits are present (fail loud if the base drifts).
command -v podman >/dev/null || { echo "podman missing — LLM enablement broken"; exit 1; }

install -Dm0644 /dev/stdin /usr/share/kinoite/north-llm-TODO.md << 'EOF'
# kinoite-north: local LLM (containerized ROCm) — TODO

ROCm/lemonade run in containers, not on the host. Enabling bits shipped:
podman, podman-compose, distrobox, and a udev rule tagging /dev/kfd for
`uaccess` so logind ACLs it to the active seat user. No group membership needed
for a local login; headless/SSH use has no active seat, so that case still
needs `usermod -aG render,video <user>`.

Pending: choose a gfx1201-capable ROCm 7.2+ container image, verify rootless
/dev/kfd passthrough, and add a Quadlet `.container` unit for lemonade (enable
it from services-north.sh). Tracked in notes/kinoite-north-validation.md.
EOF
