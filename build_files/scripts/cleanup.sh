#!/bin/bash
set -ouex pipefail

### Remove third-party repo files — updates come from CI rebuilds, not live dnf
rm -f \
    /etc/yum.repos.d/1password.repo \
    /etc/yum.repos.d/google-chrome.repo \
    /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:phracek:PyCharm.repo \
    /etc/yum.repos.d/tailscale.repo
