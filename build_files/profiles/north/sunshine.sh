#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# Sunshine game-streaming host + KDE Wayland virtual display (no dummy plug).
#
# COPR: pvermeer/sunshine — targets Fedora Atomic, carries the spec fixes
# LizardByte's own (unmaintained) `stable` COPR lacks. `sunshine-beta` is weekly.
#
# Streaming the virtual monitor takes all three of:
#   capture = kwin  — kms enumerates DRM connectors only, so it discards the
#                     virtual monitor and silently streams the physical panel
#   output_name     — kwin capture takes the first output otherwise
#   global_prep_cmd — creates the monitor at the client's geometry
# All three are per-user Web UI config, so they get seeded, not baked. Pairing is
# then the only first-login step.
#
# Clipboard is KDE Connect's job — Sunshine has never shipped it.

add_copr pvermeer-sunshine pvermeer/sunshine 0B420BCBF6AF53246B69BD5E8FAB4A6FEE1312ED

### Sunshine + KDE virtual-monitor tooling
# kscreen-doctor comes from libkscreen, which Plasma already pulls in. Assert
# both binaries: a missing one should fail the build, not a stream.
install_pkgs sunshine krfb

for bin in krfb-virtualmonitor kscreen-doctor; do
    command -v "$bin" >/dev/null || { echo "sunshine.sh: missing $bin" >&2; exit 1; }
done

# KWin gates the screencast protocol on a desktop file claiming it for the
# binary. Absent => built without SUNSHINE_ENABLE_KWIN, and Sunshine falls back
# to writing a temporary one at runtime (3s stall, needs a restart).
test -f /usr/share/applications/dev.lizardbyte.app.Sunshine.kwin.desktop || {
    echo "sunshine.sh: KWin permission desktop file missing — built without SUNSHINE_ENABLE_KWIN?" >&2
    exit 1
}

### Config seeding (runs from ExecStartPre)
# The Web UI owns this file, so only ever add missing keys — UI settings win.
cat > /usr/libexec/sunshine-config-defaults << 'EOF'
#!/bin/bash
set -euo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf"
mkdir -p "$(dirname "$CONF")"
touch "$CONF"

seed() {
    if grep -qE "^[[:space:]]*$1[[:space:]]*=" "$CONF"; then
        return 0
    fi
    printf '%s = %s\n' "$1" "$2" >> "$CONF"
    echo "sunshine-config-defaults: seeded $1 = $2"
}

seed capture kwin
seed output_name Virtual-sunshine-vm
# Runs for every app, so the virtual monitor exists before capture starts.
seed global_prep_cmd '[{"do":"/usr/libexec/sunshine-virtual-display up","undo":"/usr/libexec/sunshine-virtual-display down","elevated":false}]'
EOF
chmod +x /usr/libexec/sunshine-config-defaults

### Virtual-display helper
cat > /usr/libexec/sunshine-virtual-display << 'EOF'
#!/bin/bash
# KDE Wayland virtual monitor for Sunshine streaming (no dummy plug).
# Usage: sunshine-virtual-display up [--exclusive] [WIDTH HEIGHT [FPS]]
#        sunshine-virtual-display down
# Sunshine → Configuration → General → Command Preparation:
#   Do: `... up`   Undo: `... down`
#
# Geometry comes from SUNSHINE_CLIENT_{WIDTH,HEIGHT,FPS}; args are for testing.
#
# --exclusive (or SUNSHINE_VD_EXCLUSIVE=1) disables the physical outputs for the
# stream. Without it only new windows land on the virtual display, since primary
# is all KWin honours; disabling an output is what makes KWin migrate windows
# already running on it. Per-app is the point of the flag: Sunshine parses prep
# commands without a shell, so an env var can't be set from an app entry.

set -euo pipefail
VM_NAME="sunshine-vm"
OUTPUT="Virtual-${VM_NAME}"
# Not /tmp: a fixed name there is a predictable path into kill(1).
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="${RUNDIR}/${VM_NAME}.pid"
DISABLEDFILE="${RUNDIR}/${VM_NAME}.disabled-outputs"
PRIMARYFILE="${RUNDIR}/${VM_NAME}.prev-primary"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf"

log() { echo "sunshine-virtual-display: $*" >&2; }

is_dim() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# kscreen-doctor colours its output even when piped.
outputs_state() {
    kscreen-doctor -o 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g'
}

# "Output: <id> <name> <uuid>" header plus its indented properties.
output_block() {
    outputs_state | awk -v want="$OUTPUT" '
        /^Output:/ { inblock = ($3 == want) }
        inblock
    '
}

enabled_outputs() {
    outputs_state | awk '
        /^Output:/ { name = $3; next }
        name != "" && $1 == "enabled" { print name; name = "" }
    '
}

primary_output() {
    outputs_state | awk '
        /^Output:/ { name = $3; next }
        name != "" && $1 == "priority" && $2 == "1" { print name; exit }
    '
}

teardown() {
    # Physical outputs first: dropping the virtual one while it's the only
    # enabled output leaves KWin nowhere to put the desktop.
    if [ -s "$DISABLEDFILE" ]; then
        while read -r out; do
            kscreen-doctor "output.${out}.enable" || log "could not re-enable ${out}"
        done < "$DISABLEDFILE"
    fi
    if [ -s "$PRIMARYFILE" ]; then
        prev=$(cat "$PRIMARYFILE")
        if [ -n "$prev" ] && [ "$prev" != "$OUTPUT" ]; then
            kscreen-doctor "output.${prev}.priority.1" || log "could not restore ${prev} as primary"
        fi
    fi
    rm -f "$DISABLEDFILE" "$PRIMARYFILE"

    if [ -s "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        # PIDs get recycled — only signal it if it's still krfb.
        case "$(cat "/proc/$pid/comm" 2>/dev/null || true)" in
            krfb-virtualmo*) kill "$pid" 2>/dev/null || true ;;
        esac
    fi
    rm -f "$PIDFILE"
}

case "${1:-}" in
    up)
        shift
        exclusive="${SUNSHINE_VD_EXCLUSIVE:-0}"
        if [ "${1:-}" = "--exclusive" ]; then
            exclusive=1
            shift
        fi
        W="${1:-${SUNSHINE_CLIENT_WIDTH:-}}"
        H="${2:-${SUNSHINE_CLIENT_HEIGHT:-}}"
        FPS="${3:-${SUNSHINE_CLIENT_FPS:-}}"
        FPS="${FPS%.*}"
        if ! is_dim "$W" 640 7680 || ! is_dim "$H" 360 4320; then
            log "bad geometry [${W}x${H}], using 2560x1440"
            W=2560; H=1440
        fi
        if ! is_dim "$FPS" 24 480; then
            FPS=60
        fi

        # Clear any monitor left by a session that never ran its undo.
        teardown
        # Saved before anything changes, so teardown can put it back.
        primary_output > "$PRIMARYFILE" || true

        # --password/--port are mandatory args; the VNC side goes unused.
        krfb-virtualmonitor --name "$VM_NAME" --resolution "${W}x${H}" \
            --password sunshine --port 5905 &
        pid=$!
        echo "$pid" > "$PIDFILE"
        # Backgrounded, so a failed launch otherwise looks just like a good one.
        ready=false
        for _ in $(seq 50); do
            if [ -n "$(output_block)" ]; then
                ready=true
                break
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
                log "krfb-virtualmonitor exited"
                teardown
                exit 1
            fi
            sleep 0.1
        done
        if [ "$ready" != true ]; then
            log "timed out waiting for ${OUTPUT}"
            teardown
            exit 1
        fi

        # krfb has no refresh-rate flag — the monitor always arrives at 60Hz.
        # addCustomMode registers (mHz, dot-separated) and appends blindly; mode
        # applies it (WxH@rate, rounded).
        if ! output_block | grep -q "${W}x${H}@${FPS}\."; then
            kscreen-doctor "output.${OUTPUT}.addCustomMode.${W}.${H}.$((FPS * 1000)).full" \
                || log "addCustomMode ${W}x${H}@${FPS} failed"
        fi
        kscreen-doctor "output.${OUTPUT}.mode.${W}x${H}@${FPS}" \
            || log "could not apply ${W}x${H}@${FPS} — staying at the default mode"

        # Primary, so Big Picture and games open on the streamed monitor.
        kscreen-doctor "output.${OUTPUT}.enable" "output.${OUTPUT}.priority.1" \
            || log "could not make ${OUTPUT} primary"

        # A mismatch streams the desk with no error anywhere — say so in
        # Sunshine's own log, which is where this stderr lands.
        if ! grep -qE '^[[:space:]]*capture[[:space:]]*=[[:space:]]*kwin' "$CONF" 2>/dev/null; then
            log "WARNING: capture is not kwin in ${CONF} — kms cannot see ${OUTPUT}"
        fi
        configured=$(sed -n 's/^[[:space:]]*output_name[[:space:]]*=[[:space:]]*//p' "$CONF" 2>/dev/null | tail -1)
        if [ "${configured:-}" != "$OUTPUT" ]; then
            log "WARNING: output_name is [${configured:-unset}], expected [${OUTPUT}] — Sunshine will capture whichever output enumerates first"
        fi

        # Last: nothing that can fail should run while the desk is dark.
        if [ "$exclusive" = 1 ]; then
            : > "$DISABLEDFILE"
            for out in $(enabled_outputs); do
                if [ "$out" != "$OUTPUT" ]; then
                    if kscreen-doctor "output.${out}.disable"; then
                        echo "$out" >> "$DISABLEDFILE"
                    else
                        log "could not disable ${out}"
                    fi
                fi
            done
        fi
        ;;
    down)
        teardown
        ;;
    *)
        echo "usage: $0 up [--exclusive] [WIDTH HEIGHT [FPS]] | down" >&2; exit 2 ;;
esac
EOF
chmod +x /usr/libexec/sunshine-virtual-display

### Service drop-in
# ExecStopPost, not just Sunshine's undo command: undo only runs on a clean app
# exit, so a crash would strand the monitor — and in exclusive mode, dark panels.
mkdir -p /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d
cat > /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/10-kinoite-north.conf << 'EOF'
[Service]
ExecStartPre=-/usr/libexec/sunshine-config-defaults
ExecStopPost=-/usr/libexec/sunshine-virtual-display down
EOF
