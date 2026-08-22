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

### Build residue in runtime-only and machine-local paths (both are bootc lint warnings)
# /run and /tmp are tmpfs at runtime, so anything baked into them is masked at boot and can
# never be read — dnf, systemctl and mcstrans all leave directories behind. Content under
# /var only seeds a fresh machine's /var, which makes dnf's repo cache and the `countme`
# files it writes equally pointless. rpm's own db under /var/lib/rpm is deliberately left
# alone: bake_sbom runs after this and queries it.
find /run /tmp -mindepth 1 -delete 2>/dev/null || true
rm -rf /var/lib/dnf/repos
