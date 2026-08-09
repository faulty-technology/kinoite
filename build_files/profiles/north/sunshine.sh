#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# Sunshine game-streaming host + KDE Wayland virtual display (the Apollo-equivalent
# "no dummy plug" setup).
#
# Sourced from pvermeer/sunshine rather than LizardByte's own COPR: it targets
# Fedora Atomic explicitly, carries spec fixes for the build issues that made
# Bazzite drop its native Sunshine, and LizardByte's `stable` COPR is not
# actually maintained by LizardByte. Package is lowercase `sunshine` (stable);
# `sunshine-beta` tracks the weekly pre-release.
#
# Clipboard sync is not part of this — that's KDE Connect. Sunshine has never
# shipped it.
#
# TODO(hardware): validate krfb-virtualmonitor drives a client-scaled virtual
# monitor into Sunshine on RDNA4/Wayland. See notes/kinoite-north-validation.md.

add_copr pvermeer-sunshine pvermeer/sunshine 0B420BCBF6AF53246B69BD5E8FAB4A6FEE1312ED

### Install Sunshine + the KDE virtual-monitor tooling
# krfb provides /usr/bin/krfb-virtualmonitor. kscreen-doctor, for inspecting or
# tweaking the virtual output, lives in libkscreen (NOT the kscreen package) and
# Plasma already pulls that in — nothing to add for it.
install_pkgs sunshine krfb

### Virtual-display helper
# Sunshine's default kms capture cannot see a krfb virtual monitor — capture must
# be forced to "kwin" (Sunshine Web UI → Configuration → Advanced → Force Capture
# Method → kwin). That is per-user app config, so it is a documented first-login
# step rather than baked. This helper spins up a right-sized virtual monitor and
# is intended to be wired into Sunshine's "Command Preparations" (do/undo) so a
# client connection brings the display up and tears it down on disconnect.
cat > /usr/libexec/sunshine-virtual-display << 'EOF'
#!/bin/bash
# Bring up a KDE Wayland virtual monitor for Sunshine streaming (no dummy plug).
# Usage: sunshine-virtual-display up|down [WIDTH HEIGHT]
# Wire into Sunshine: Configuration → General → Command Preparation
#   Do:   /usr/libexec/sunshine-virtual-display up   ${SUNSHINE_CLIENT_WIDTH} ${SUNSHINE_CLIENT_HEIGHT}
#   Undo: /usr/libexec/sunshine-virtual-display down
set -euo pipefail
VM_NAME="sunshine-vm"
# Not /tmp: a fixed name there is a predictable path we feed straight to kill(1).
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/${VM_NAME}.pid"
case "${1:-}" in
    up)
        W="${2:-2560}"; H="${3:-1440}"
        # --password/--port are required by krfb-virtualmonitor even though the
        # VNC side goes unused here (Sunshine captures via kwin, not VNC).
        krfb-virtualmonitor --name "$VM_NAME" --resolution "${W}x${H}" \
            --password sunshine --port 5905 &
        echo $! > "$PIDFILE"
        ;;
    down)
        if [ -s "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE")
            # Only signal it if it's still the virtual monitor — PIDs get recycled.
            case "$(cat "/proc/$pid/comm" 2>/dev/null || true)" in
                krfb-virtualmo*) kill "$pid" 2>/dev/null || true ;;
            esac
        fi
        rm -f "$PIDFILE"
        ;;
    *)
        echo "usage: $0 up|down [WIDTH HEIGHT]" >&2; exit 2 ;;
esac
EOF
chmod +x /usr/libexec/sunshine-virtual-display
