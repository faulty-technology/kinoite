#!/bin/bash
set -ouex pipefail

### Enable systemd units
systemctl enable podman.socket
systemctl enable bootc-fetch.timer
