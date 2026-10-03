#!/bin/bash
set -ouex pipefail

# Profile: nuc — headless k3s home server (ghcr.io/faulty-technology/kinoite-nuc).
# Intel NUC12WSKi7 / i7-1260P / Iris Xe / I225-V.
#
# Built on fedora-bootc, not Kinoite: no desktop, so none of the desktop baseline
# (1Password, Chrome, codecs, Nix, fonts). Shares Tailscale, bootc update services,
# signing and cleanup with the other images. Workloads are not in the image — Flux
# reconciles them into k3s from a separate GitOps repo.

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(cd "$PROFILE_DIR/../../scripts" && pwd)"

. "$SHARED/lib/common.sh"

# Read by services.sh: reboot into updates on a weekly window instead of staging them.
export UPDATE_POLICY=apply

# Shared repos + third-party apps (repo files removed again in cleanup.sh)
"$SHARED/tailscale.sh"

# Profile-specific installs
"$PROFILE_DIR/packages.sh"
"$PROFILE_DIR/k3s.sh"
"$PROFILE_DIR/nfs.sh"
"$PROFILE_DIR/host.sh"

# Shared runtime setup + finalization
"$SHARED/services.sh"
"$PROFILE_DIR/services-nuc.sh"
"$SHARED/signing.sh"
"$SHARED/cleanup.sh"

# Bake additive SBOM data into the image
bake_sbom
