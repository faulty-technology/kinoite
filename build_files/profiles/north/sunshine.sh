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
#   Do:   /usr/libexec/sunshine-virtual-display up
#   Undo: /usr/libexec/sunshine-virtual-display down

set -euo pipefail
VM_NAME="sunshine-vm"
# Not /tmp: a fixed name there is a predictable path we feed straight to kill(1).
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/${VM_NAME}.pid"

is_dim() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

case "${1:-}" in
    up)
        W="${2:-${SUNSHINE_CLIENT_WIDTH:-}}"
        H="${3:-${SUNSHINE_CLIENT_HEIGHT:-}}"
        if ! is_dim "$W" 640 7680 || ! is_dim "$H" 360 4320; then
            echo "sunshine-virtual-display: bad geometry [${W}x${H}], using 2560x1440" >&2
            W=2560; H=1440
        fi
        # --password/--port are required by krfb-virtualmonitor even though the
        # VNC side goes unused here (Sunshine captures via kwin, not VNC).
        krfb-virtualmonitor --name "$VM_NAME" --resolution "${W}x${H}" \
            --password sunshine --port 5905 &
        pid=$!
        echo "$pid" > "$PIDFILE"
        # Backgrounding krfb means a failed launch otherwise looks identical to a
        # good one, and Sunshine starts capturing a display that never arrived.
        for _ in $(seq 50); do
            if kscreen-doctor -o 2>/dev/null | grep -q "Virtual-${VM_NAME}"; then
                exit 0
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "sunshine-virtual-display: krfb-virtualmonitor exited" >&2
                rm -f "$PIDFILE"
                exit 1
            fi
            sleep 0.1
        done
        echo "sunshine-virtual-display: timed out waiting for ${VM_NAME}" >&2
        exit 1
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
