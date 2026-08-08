#!/bin/bash
set -ouex pipefail

### Remove unwanted base image packages
dnf5 remove -y firefox firefox-langpacks

### Install standard Fedora packages
# Same core as the laptop image MINUS laptop-only bits (intel-media-driver,
# powertop). distrobox + podman-compose double as the containerized-LLM
# enablers (ROCm/lemonade run in containers — see llm.sh).
PACKAGES=(
    distrobox
    lm_sensors
    podman-compose
)

dnf5 install -y "${PACKAGES[@]}"
printf '%s\n' "${PACKAGES[@]}" >> /usr/share/kinoite/packages
