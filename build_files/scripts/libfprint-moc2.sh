#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Install the locally-built libfprint RPM (elanmoc2 driver + 04f3:0c99 entry)
# Built by .github/workflows/build.yml via scripts/build-libfprint-moc2-rpm.sh and staged
# into the ctx stage by the same job. Displaces the stock libfprint; the
# assertion fails the build if the floating base ever ships a newer stock
# libfprint that dnf would prefer over ours.
RPM=$(ls /ctx/rpms/libfprint-*.rpm 2>/dev/null || true)
if [ -z "$RPM" ]; then
    echo "WARN: no moc2 RPM staged — keeping stock libfprint"
    exit 0
fi
dnf5 install -y "$RPM"
record_pkgs libfprint
rpm -q libfprint | grep -q moc2 || { echo "ERROR: libfprint is not the moc2 build"; exit 1; }
