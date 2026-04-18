#!/bin/bash
set -ouex pipefail

mkdir -p /usr/share/kinoite
SCRIPT_DIR="$(dirname "$0")/scripts"

for script in rpmfusion 1password google-chrome tailscale gh-cli packages services signing cleanup; do
    "$SCRIPT_DIR/${script}.sh"
done

# Bake additive SBOM data into the image
rpm -q --queryformat "%{NAME}\t%{VERSION}-%{RELEASE}\t%{LICENSE}\n" \
    $(cat /usr/share/kinoite/packages) > /usr/share/kinoite/additive-sbom.tsv
