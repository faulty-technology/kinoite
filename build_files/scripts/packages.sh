#!/bin/bash
set -ouex pipefail

### Install standard Fedora packages
PACKAGES=(
    distrobox
    intel-media-driver
    lm_sensors
    podman-compose
    powertop
)

dnf5 install -y "${PACKAGES[@]}"
printf '%s\n' "${PACKAGES[@]}" >> /usr/share/kinoite/packages
