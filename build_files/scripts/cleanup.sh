#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Remove third-party repo files — updates come from CI rebuilds, not live dnf
# Repo files register themselves as they're written (lib/pkg.sh), so this can't
# drift out of sync with what was actually added. The verified keys stay in
# /etc/pki/rpm-gpg — they record what signed the layered packages.
if [ -s "$REPO_REGISTRY" ]; then
    xargs -r rm -f < "$REPO_REGISTRY"
fi

# Shipped by the base image, not by us.
rm -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:phracek:PyCharm.repo
