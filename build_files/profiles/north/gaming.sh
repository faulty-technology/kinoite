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
