#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### Remove unwanted base image packages
dnf5 remove -y firefox firefox-langpacks

### Install standard Fedora packages
# Same core as the laptop image MINUS laptop-only bits (intel-media-driver,
# powertop). distrobox + podman-compose double as the containerized-LLM
# enablers (ROCm/lemonade run in containers — see llm.sh).
install_pkgs \
    distrobox \
    lm_sensors \
    podman-compose
