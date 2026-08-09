#!/bin/bash
set -ouex pipefail

# Lean gaming core. Everything else (emulators, Lutris, Heroic, ...) is added
# as-needed via Flatpak or distrobox — kept out of the image on purpose.
#
# steam lives in rpmfusion-nonfree (set up by the shared rpmfusion.sh) and pulls
# in i686 multilib deps. gamescope / gamemode / mangohud are in the Fedora repos.
PACKAGES=(
    steam
    gamescope
    gamemode
    mangohud
)

dnf5 install -y "${PACKAGES[@]}"
printf '%s\n' "${PACKAGES[@]}" >> /usr/share/kinoite/packages

### 32-bit VA-API for Proton (must follow steam, which drags in the i686 stack)
# steam is an i686 package, so 32-bit titles use the i686 mesa drivers. Give
# them the same VA-API driver codecs.sh installed for the 64-bit side.
dnf5 install -y mesa-va-drivers-freeworld.i686
