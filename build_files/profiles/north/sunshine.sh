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
# do:   creates the virtual monitor on demand (or resizes it if the client geometry
#       changed). It is no longer created at login — see sunshine.sh.
# undo: tears it down so krfb stops holding a render node and the GPU backing it can
#       runtime-suspend between streams. `down` re-enables any output an --exclusive
#       stream disabled, and refuses to run at all if no physical output is connected.
# Sunshine prep_cmd only understands "do", "undo", "elevated" — no "args" key.
seed global_prep_cmd '[{"do":"/usr/libexec/sunshine-virtual-display ensure","undo":"/usr/libexec/sunshine-virtual-display down","elevated":false}]'
EOF
chmod +x /usr/libexec/sunshine-config-defaults

### Virtual-display helper
cat > /usr/libexec/sunshine-virtual-display << 'EOF'
#!/bin/bash
# KDE Wayland virtual monitor for Sunshine streaming (no dummy plug).
# Usage: sunshine-virtual-display up [--exclusive] [WIDTH HEIGHT [FPS]]
#        sunshine-virtual-display ensure [--exclusive] [WIDTH HEIGHT [FPS]]
#        sunshine-virtual-display down
# Sunshine → Configuration → General → Command Preparation:
#   Global: Do: `/usr/libexec/sunshine-virtual-display ensure`
#           Undo: `/usr/libexec/sunshine-virtual-display down` (seeded; restores outputs
#                 AND drops the monitor so the GPU backing it can suspend between streams)
#   Per-app override: Do: `/usr/libexec/sunshine-virtual-display ensure --exclusive` (darkens physical outputs)
#   Clean up if stranded: `/usr/libexec/sunshine-virtual-display down`
#
# Geometry comes from SUNSHINE_CLIENT_{WIDTH,HEIGHT,FPS}; args are for testing.
#
# --exclusive (or SUNSHINE_VD_EXCLUSIVE=1 with `up`) disables the physical outputs for the
# stream. The seeded `ensure` path only honours the `--exclusive` flag. Without it only new windows land on the virtual display, since primary
# is all KWin honours; disabling an output is what makes KWin migrate windows
# already running on it. Per-app is the point of the flag: Sunshine parses prep
# commands without a shell, so an env var can't be set from an app entry.

set -euo pipefail
VM_NAME="sunshine-vm"
OUTPUT="Virtual-${VM_NAME}"
# Not /tmp: a fixed name there is a predictable path into kill(1).
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="${RUNDIR}/${VM_NAME}.pid"

# The output-restore state MUST outlive a reboot, so it does NOT live beside the
# pidfile. It used to: XDG_RUNTIME_DIR is tmpfs, so an --exclusive stream that never
# ran its undo (crash, hard reboot, power cut) lost the restore list — while KDE
# persisted the *disabled* state in ~/.config/kwinoutputconfig.json. Net result was a
# box with its physical displays off and nothing left that knew how to turn them back
# on. The pidfile stays in the runtime dir deliberately: a PID from a previous boot is
# worse than no PID at all.
STATEDIR="${XDG_STATE_HOME:-$HOME/.local/state}/${VM_NAME}"
mkdir -p "$STATEDIR"
DISABLEDFILE="${STATEDIR}/disabled-outputs"
PRIMARYFILE="${STATEDIR}/prev-primary"
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

# Every *connected* output that isn't ours, enabled or not. enabled_outputs() can't
# answer this — a disabled output is exactly the one we need to find.
physical_outputs() {
    outputs_state | awk -v skip="$OUTPUT" '
        /^Output:/ { name = $3; next }
        name != "" && $1 == "connected" { if (name != skip) print name; name = "" }
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
    ensure)
        shift
        # --exclusive toggles physical output disabling to force KWin to migrate windows.
        # With the persistent display, this is how users enable/disable exclusivity
        # per-app: set `ensure --exclusive` globally or for a single app entry.
        # Called without --exclusive re-enables any previously disabled outputs.
        exclusive_wanted=false
        if [ "${1:-}" = "--exclusive" ]; then
            exclusive_wanted=true
            shift
        fi
        W="${1:-${SUNSHINE_CLIENT_WIDTH:-2560}}"
        H="${2:-${SUNSHINE_CLIENT_HEIGHT:-1440}}"
        FPS="${3:-${SUNSHINE_CLIENT_FPS:-60}}"
        FPS="${FPS%.*}"
        if ! is_dim "$W" 640 7680 || ! is_dim "$H" 360 4320; then
            log "bad geometry [${W}x${H}], using 2560x1440"
            W=2560; H=1440
        fi
        if ! is_dim "$FPS" 24 480; then
            FPS=60
        fi

        # Already running? Just resize — no teardown, no re-launch.
        if [ -s "$PIDFILE" ] && [ -n "$(output_block)" ]; then
            kscreen-doctor "output.${OUTPUT}.enable" || log "could not enable ${OUTPUT}"
            if ! output_block | grep -q "${W}x${H}@${FPS}\."; then
                kscreen-doctor "output.${OUTPUT}.addCustomMode.${W}.${H}.$((FPS * 1000)).full" \
                    || log "addCustomMode ${W}x${H}@${FPS} failed"
            fi
            kscreen-doctor "output.${OUTPUT}.mode.${W}x${H}@${FPS}" \
                || log "could not apply ${W}x${H}@${FPS}"
            kscreen-doctor "output.${OUTPUT}.priority.1" || log "could not set ${OUTPUT} as primary"
            log "resized persistent display to ${W}x${H}@${FPS}"

            # Apply or clear exclusivity
            if [ "$exclusive_wanted" = true ]; then
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
            elif [ -s "$DISABLEDFILE" ]; then
                # Re-enable outputs that were disabled by a previous --exclusive stream
                while read -r out; do
                    kscreen-doctor "output.${out}.enable" || log "could not re-enable ${out}"
                done < "$DISABLEDFILE"
                rm -f "$DISABLEDFILE"
            fi
            exit 0
        fi
        # Not running — fall through to up to create it with the resolved geometry.
        if [ "$exclusive_wanted" = true ]; then
            "$0" up --exclusive "$W" "$H" "$FPS"
        else
            "$0" up "$W" "$H" "$FPS"
        fi
        ;;
    up)
        shift
        exclusive="${SUNSHINE_VD_EXCLUSIVE:-0}"
        persistent="${SUNSHINE_VD_PERSISTENT:-0}"  # default 0: --persistent must be explicit
        while [ $# -gt 0 ]; do
            case "$1" in
                --exclusive) exclusive=1; shift ;;
                --persistent) persistent=1; shift ;;
                *) break ;;
            esac
        done
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

        # Clear any monitor left by a session that never ran its undo. teardown
        # re-enables whatever the restore list recorded, which now survives reboots.
        teardown

        # Login safety net, for when the restore list itself is gone or was never
        # written — a KDE-persisted disabled output, or state predating the STATEDIR
        # move. Only on the login path: a manual `up --exclusive` is a deliberate
        # request for a dark desk and must not be undone here.
        if [ "$persistent" = 1 ] && [ -z "$(enabled_outputs | grep -v "^${OUTPUT}$")" ]; then
            log "no enabled physical output at login — restoring all connected outputs"
            for out in $(physical_outputs); do
                kscreen-doctor "output.${out}.enable" \
                    && log "restored ${out}" \
                    || log "could not restore ${out}"
            done
        fi

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
        if [ -f "$CONF" ]; then
            if ! grep -qE '^[[:space:]]*capture[[:space:]]*=[[:space:]]*kwin' "$CONF" 2>/dev/null; then
                log "WARNING: capture is not kwin in ${CONF} — kms cannot see ${OUTPUT}"
            fi
            configured=$(sed -n 's/^[[:space:]]*output_name[[:space:]]*=[[:space:]]*//p' "$CONF" 2>/dev/null | tail -1)
            if [ "${configured:-}" != "$OUTPUT" ]; then
                log "WARNING: output_name is [${configured:-unset}], expected [${OUTPUT}] — Sunshine will capture whichever output enumerates first"
            fi
        fi

        # Last: nothing that can fail should run while the desk is dark.
        # --persistent (passed by the login service): never disable physical outputs.
        # --exclusive without --persistent darkens the desk so KWin migrates windows.
        if [ "$exclusive" = 1 ] && [ "$persistent" = 0 ]; then
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
        # Refuse to strand a headless box. teardown re-enables any physical output it
        # disabled, so a merely-disabled display is fine — but if no physical output is
        # *connected* at all, the virtual one is the only thing KWin has, and dropping
        # it can leave the compositor at zero outputs, deadlock the GPU, and take SSH
        # with it. In that configuration the persistent unit is what should own the
        # display anyway (see sunshine.sh).
        if [ -z "$(physical_outputs)" ]; then
            log "refusing to tear down: no connected physical output to fall back to"
            exit 0
        fi
        teardown
        ;;
    *)
        echo "usage: $0 {ensure|up} [--exclusive] [WIDTH HEIGHT [FPS]] | down" >&2; exit 2 ;;
esac
EOF
chmod +x /usr/libexec/sunshine-virtual-display

### Service drop-in
# No teardown here — the persistent virtual display service owns that lifecycle.
# ExecStopPost runs `ensure` to restore physical outputs if the last stream was exclusive.
mkdir -p /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d
cat > /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/10-kinoite-north.conf << 'EOF'
[Service]
ExecStartPre=-/usr/libexec/sunshine-config-defaults
# Needed so global_prep_cmd's kscreen-doctor calls reach the compositor
Environment=WAYLAND_DISPLAY=wayland-0
ExecStopPost=-/usr/libexec/sunshine-virtual-display ensure
EOF

### Virtual display unit — SHIPPED BUT NOT ENABLED (changed 2026-08-18)
# It used to be `systemctl --global enable`d, so every login started krfb whether or
# not anyone streamed. krfb-virtualmonitor holds a DRM render node for as long as it
# runs, which pins whichever GPU backs it into D0 — the same class of problem as the
# CoolerControl polling (see motherboard.sh). On this box that meant a dedicated GPU
# awake at ~30% fan around the clock for a monitor nobody was looking at.
#
# Streaming does not need it at login: the seeded global_prep_cmd runs `ensure`, which
# falls through to `up` and creates the display on demand when a stream starts.
#
# Kept as a shipped-but-disabled unit because it is still the right answer for a
# genuinely headless box, where losing the virtual output means KWin reaches zero
# outputs — which can deadlock the GPU and take SSH with it. With a physical display
# attached there is always another output, so the risk does not apply.
#   Headless setup:  systemctl --user enable --now sunshine-virtual-monitor.service
# Resolved via WantedBy=graphical-session.target — it's per-user.
cat > /usr/lib/systemd/user/sunshine-virtual-monitor.service << 'EOF'
[Unit]
Description=Sunshine persistent virtual display
Documentation=https://github.com/LizardByte/Sunshine
# systemd does not glob unit names — use the session target for ordering.
# PartOf propagates stop/restart from the target so killing the session
# also tears down the virtual display; see the comment below for RemainAfterExit.
After=graphical-session.target
PartOf=graphical-session.target
Before=app-dev.lizardbyte.app.Sunshine.service

[Service]
Type=oneshot
RemainAfterExit=yes
# RemainAfterExit=yes is required: without it the cgroup (and thus the backgrounded krfb)
# is torn down immediately when ExecStart's parent exits.
Environment=DISPLAY=:0 WAYLAND_DISPLAY=wayland-0
ExecStart=/usr/libexec/sunshine-virtual-display up --persistent 2560 1440 60

[Install]
WantedBy=graphical-session.target
EOF


# Deliberately NOT enabled — see the block above. A `systemctl --global enable` here
# would also be undoable only with `systemctl --user mask`, not `--user disable`, which
# is a nasty surprise for anyone trying to turn it off on one machine.
