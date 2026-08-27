#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### Remove unwanted base image packages
dnf5 remove -y firefox firefox-langpacks

### Install standard Fedora packages
# Same core as the laptop image MINUS laptop-only bits (intel-media-driver,
# powertop). distrobox + podman-compose double as the containerized-LLM
# enablers (ROCm/lemonade run in containers — see lemonade.sh).
#
# python3-huggingface-hub is the HOST-side Hugging Face CLI (/usr/bin/hf, plus
# huggingface-cli and tiny-agents). It exists so pulling a base model is `hf download`
# rather than a Python snippet inside whichever container happens to be running, and so
# `hf auth login` can write one token that all three LLM stacks pick up — see the
# HF_HOME profile.d snippet in unsloth.sh for how that reaches them.
install_pkgs \
    distrobox \
    lm_sensors \
    podman-compose \
    python3-huggingface-hub
