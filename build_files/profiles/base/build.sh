#!/bin/bash
set -ouex pipefail

# Profile: base — laptop / dev machine (ghcr.io/faulty-technology/kinoite)
# Orchestrates the shared, image-agnostic scripts plus this profile's packages.

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(cd "$PROFILE_DIR/../../scripts" && pwd)"

mkdir -p /usr/share/kinoite

# Shared repos + third-party apps (repo files removed again in cleanup.sh)
"$SHARED/rpmfusion.sh"
"$SHARED/codecs.sh"
"$SHARED/1password.sh"
"$SHARED/google-chrome.sh"
"$SHARED/tailscale.sh"

# Profile-specific package set
"$PROFILE_DIR/packages.sh"

# Shared runtime setup + finalization (order: nix/fonts/services, then sign, then cleanup)
"$SHARED/nix.sh"
"$SHARED/fonts.sh"
"$SHARED/services.sh"
"$SHARED/signing.sh"
"$SHARED/cleanup.sh"

# Bake additive SBOM data into the image
. "$SHARED/lib/sbom.sh"
bake_sbom
