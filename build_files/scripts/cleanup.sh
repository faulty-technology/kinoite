#!/bin/bash
set -ouex pipefail

### Remove third-party repo files — updates come from CI rebuilds, not live dnf
# The three COPRs (LizardByte/LACT/CoolerControl) are north-only; removing a
# missing file is a harmless no-op on the base image (rm -f). The verified keys
# in /etc/pki/rpm-gpg stay — they record what signed the layered packages.
rm -f \
    /etc/yum.repos.d/1password.repo \
    /etc/yum.repos.d/google-chrome.repo \
    /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:phracek:PyCharm.repo \
    /etc/yum.repos.d/_copr_lizardbyte-beta.repo \
    /etc/yum.repos.d/_copr_ilyaz-LACT.repo \
    /etc/yum.repos.d/_copr_codifryed-CoolerControl.repo \
    /etc/yum.repos.d/tailscale.repo
