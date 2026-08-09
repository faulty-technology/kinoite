#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### Remove unwanted base image packages
dnf5 remove -y firefox firefox-langpacks

### Install standard Fedora packages
install_pkgs \
    distrobox \
    intel-media-driver \
    lm_sensors \
    podman-compose \
    powertop
