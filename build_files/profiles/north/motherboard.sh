#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/verify-key.sh"

# ASUS ProArt B850-Creator WiFi Neo enablement.
# Super I/O: Nuvoton NCT6701D | Wi-Fi: RTL8922AE (rtw89) | LAN: dual Realtek 5GbE
# (RTL8126, r8169). Wi-Fi/LAN/audio work in-kernel on Fedora 44 — nothing to bake
# for them (verify post-install). The board-specific win is sensor/fan access.

### 1. Motherboard sensors + fan access
# ASUS boards let ACPI reserve the Super I/O I/O region, so nct6775 won't load
# and lm_sensors/LACT/fan tools see no motherboard fan RPM, voltages, or board
# temps. acpi_enforce_resources=lax lets the native driver claim the region.
# Tradeoff: the kernel driver and the EC can both touch the Super I/O — the
# standard ASUS fix, low practical risk. Baked declaratively via bootc kargs.d.
#
# TODO(hardware): the NCT6701D is new — fan/voltage read fine, but several temp
# channels read 0C or are missing until asus-ec-sensors gains an entry for this
# board. Recheck on newer kernels. See notes/kinoite-north-validation.md.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/20-sensors.toml << 'EOF'
kargs = ["acpi_enforce_resources=lax"]
match-architectures = ["x86_64"]
EOF

# nct6775 won't auto-probe when the region was ACPI-reserved — force-load it.
cat > /usr/lib/modules-load.d/nct6775.conf << 'EOF'
nct6775
EOF

### 2. CoolerControl — GUI fan-curve control for CPU/case/AIO fans
# The system-fan counterpart to LACT (which handles the GPUs). Reads the sensors
# unlocked above. Installed from the maintainer's COPR, key fingerprint-pinned.
verify_and_import_key "codifryed-coolercontrol" "CoolerControl COPR (codifryed)" \
    "https://download.copr.fedorainfracloud.org/results/codifryed/CoolerControl/pubkey.gpg" \
    E8AB88BC4834377F98A165F860E6A0997C96AB47

cat > /etc/yum.repos.d/_copr_codifryed-CoolerControl.repo << 'EOF'
[copr:copr.fedorainfracloud.org:codifryed:CoolerControl]
name=Copr repo for CoolerControl owned by codifryed
baseurl=https://download.copr.fedorainfracloud.org/results/codifryed/CoolerControl/fedora-$releasever-$basearch/
type=rpm-md
skip_if_unavailable=False
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-codifryed-coolercontrol
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF

# coolercontrold owns coolercontrold.service but is only a Recommends of the
# GUI — name it explicitly so the enable below can't break on a weak-dep change.
PACKAGES=(
    coolercontrol
    coolercontrold
)
dnf5 install -y "${PACKAGES[@]}"
printf '%s\n' "${PACKAGES[@]}" >> /usr/share/kinoite/packages

# Enable the daemon (GUI `coolercontrol` talks to it).
systemctl enable coolercontrold.service
