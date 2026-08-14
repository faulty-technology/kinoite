#!/bin/bash
set -ouex pipefail

# Wake-on-WLAN for north (ASUS ProArt B850-Creator WiFi Neo — RTL8922AE / rtw89).
# Goal: a magic packet sent to the Wi-Fi MAC resumes the box, with no per-machine
# CLI step after a rebase. BIOS-side WoL is user-provisioned and already done.
#
# WoWLAN is an **nl80211** feature. Two paths look plausible and neither works:
# mac80211 exports no `set_wol` ethtool op (see `ieee80211_ethtool_ops` in
# net/mac80211/ethtool.c), so `ethtool -s <wlan> wol g` returns EOPNOTSUPP on
# every mac80211 driver including rtw89; and `iw dev ... set power_save off`
# governs runtime power save, which is a different thing from a wake trigger —
# neither arms anything, and a `|| true` around either one buys silence, not a
# wake. The trigger must be armed over nl80211, and re-armed on every association
# and every suspend cycle, which is exactly what NetworkManager already does. So
# this is a NetworkManager connection default and nothing else: no unit, no sleep
# hook, no interface detection.
#
# Driver support is real rather than assumed: rtw8922a.c declares
# `WIPHY_WOWLAN_MAGIC_PKT` (under CONFIG_PM) in its `wowlan_stub`, so the chip's
# WoWLAN firmware path is wired up in-tree.

### NetworkManager connection default
# Vendor dir, not /etc: keeps the setting image-managed (a rebase can revise it)
# and leaves /etc/NetworkManager/conf.d free as the machine-local override. NM
# reads both. This is the one spot where north deviates from the /etc convention
# the rest of build_files/ uses — those are files a user is expected to own.
#
# wifi.wake-on-wlan=8 — the value must be the **numeric** flag. NM reads this
# default through nm_config_data_get_connection_default_int64(), so the nmcli word
# `magic` parses as 0 and silently disables it. 8 = WAKE_ON_WLAN_MAGIC. Beware the
# two exclusive no-op values while debugging: 0x1 `default` and 0x8000 `ignore`
# both mean "leave it alone", and NM falls back to `ignore` if the flag is invalid.
#
# wifi.cloned-mac-address=permanent — the magic packet is addressed to a MAC, so
# the associated MAC must be the hardware one and must be stable across reconnects.
# NM's default is already `preserve`, so this is belt-and-braces that makes the
# requirement explicit. `wifi.scan-rand-mac-address` is *not* the relevant knob: it
# only randomizes probe requests while scanning, never the associated address.
mkdir -p /usr/lib/NetworkManager/conf.d
cat > /usr/lib/NetworkManager/conf.d/20-wake-on-wlan.conf << 'EOF'
[connection-wifi-wowlan]
match-device=type:wifi
wifi.wake-on-wlan=8
wifi.cloned-mac-address=permanent
EOF

# Deliberately not set: wifi.powersave. Runtime power save is orthogonal to WoWLAN
# — the radio listens for the armed trigger from its low-power state by design —
# so disabling it burns idle watts on a 24/7 box without making the wake likelier.
#
# TODO(hardware): unverified on the real box. Two things can still swallow the wake
# with the trigger correctly armed: the PCIe function may not be marked as a wakeup
# source (rtw89 may not implement cfg80211's `set_wakeup`), and s2idle vs S3 changes
# what does the resuming. See notes/kinoite-north-validation.md.
