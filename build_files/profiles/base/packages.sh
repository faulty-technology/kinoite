#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### Remove unwanted base image packages
dnf5 remove -y firefox firefox-langpacks

### Install standard Fedora packages
# kubernetesX.Y-client is kubectl. Keep it within one minor of the k3s pinned in
# profiles/nuc/k3s.sh — kubectl supports only ±1 minor of the server.
install_pkgs \
    distrobox \
    intel-media-driver \
    kubernetes1.36-client \
    lm_sensors \
    podman-compose \
    powertop
