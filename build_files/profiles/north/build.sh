#!/bin/bash
set -ouex pipefail

# Profile: north — gaming + local-LLM battlestation
# (ghcr.io/faulty-technology/kinoite-north). Fractal North XL / AMD 9900X /
# dual Radeon AI PRO R9700 (RDNA4, gfx1201).
#
# Inherits the shared baseline (1Password, Chrome, Tailscale, Nix, fonts,
# bootc/update services, signing) and layers on AMD/RDNA4 enablement, a lean
# gaming core, and Sunshine streaming. ROCm itself stays containerized — see lemonade.sh.

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(cd "$PROFILE_DIR/../../scripts" && pwd)"

. "$SHARED/lib/common.sh"

# Shared repos + third-party apps (repo files removed again in cleanup.sh)
"$SHARED/rpmfusion.sh"
"$SHARED/codecs.sh"
"$SHARED/1password.sh"
"$SHARED/google-chrome.sh"
"$SHARED/tailscale.sh"

# Profile-specific installs
"$PROFILE_DIR/packages.sh"
"$PROFILE_DIR/amdgpu.sh"
"$PROFILE_DIR/tuning.sh"
"$PROFILE_DIR/motherboard.sh"
"$PROFILE_DIR/wol.sh"
"$PROFILE_DIR/gaming.sh"
"$PROFILE_DIR/sunshine.sh"
"$PROFILE_DIR/lemonade.sh"
"$PROFILE_DIR/vllm.sh"

# Shared runtime setup + finalization
"$SHARED/nix.sh"
"$SHARED/fonts.sh"
"$SHARED/services.sh"
"$PROFILE_DIR/services-north.sh"
"$SHARED/signing.sh"
"$SHARED/cleanup.sh"

# Bake additive SBOM data into the image
bake_sbom
