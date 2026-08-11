#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# Lean gaming core. Emulators, Lutris, Heroic, Bottles etc. are still added
# as-needed via Flatpak or distrobox — kept out of the image on purpose.
#
# steam lives in rpmfusion-nonfree (set up by the shared rpmfusion.sh) and pulls
# in i686 multilib deps. gamescope / gamemode / mangohud are in the Fedora repos.
install_pkgs steam gamescope gamemode mangohud protontricks

### 32-bit VA-API for Proton (must follow steam, which drags in the i686 stack)
# steam is an i686 package, so 32-bit titles use the i686 mesa drivers. Give
# them the same VA-API driver codecs.sh installed for the 64-bit side.
dnf5 install -y mesa-va-drivers-freeworld.i686
record_pkgs mesa-va-drivers-freeworld

### umu-launcher — Proton for non-Steam games
# Not in Fedora. Bazzite's COPR also ships patched mesa/kernel/gamescope, so
# includepkgs keeps it from swapping ours out mid-transaction.
add_copr bazzite-org-bazzite bazzite-org/bazzite E4DB8E8133162B62768D15E7B23E39ED92D38861 'umu-launcher*'

install_pkgs umu-launcher

### Proton-GE
# sha512 comes from the release's own .sha512sum — bump version and hash
# together. Steam merges ~/.steam/root/compatibilitytools.d, so ProtonUp-Qt
# still works for newer builds without a rebuild.
GE_VERSION="GE-Proton11-3"
GE_SHA512="528ae7831f909c0a4fff5d83889ac6dab3c9706746cd148f05f3064ac042763853d68277e2a815f18f16c17285d5d128864a03c563956c0dce30bafcd16aa77c"

curl -fsSL -o /tmp/ge-proton.tar.gz \
    "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_VERSION}/${GE_VERSION}.tar.gz"

echo "${GE_SHA512}  /tmp/ge-proton.tar.gz" | sha512sum -c -

mkdir -p /usr/share/steam/compatibilitytools.d
tar -xf /tmp/ge-proton.tar.gz -C /usr/share/steam/compatibilitytools.d/
rm -f /tmp/ge-proton.tar.gz

test -d "/usr/share/steam/compatibilitytools.d/${GE_VERSION}" || {
    echo "gaming.sh: ${GE_VERSION} did not extract as expected" >&2
    exit 1
}

### split lock detection off (baked kernel arg)
# The kernel's split-lock throttling costs some Proton titles ~10x frame rate.
# bootc merges every kargs.d entry (10-amdgpu, 20-sensors, 30-gaming).
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/30-gaming.toml << 'EOF'
kargs = ["split_lock_detect=off"]
match-architectures = ["x86_64"]
EOF
