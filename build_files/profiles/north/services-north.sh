#!/bin/bash
set -ouex pipefail

# north-only service enablement (shared services are handled by services.sh).

### Sunshine streaming host
# Sunshine ships a systemd *user* unit; enable it globally so it starts for the
# logged-in user. sunshine.sh drops in the ExecStartPre that seeds the capture
# settings and the global_prep_cmd that resizes the persistent virtual monitor;
# pairing and wiring the prep commands stay per-user first-login steps (see README).
#
# The virtual display is created on demand by the seeded global_prep_cmd (`ensure`)
# and destroyed by its `undo` (`down`), NOT at login — sunshine-virtual-monitor.service
# Shipped disabled as of 2026-08-18: krfb holds a render node and pins the GPU
# awake.  Full story: docs/runs/2026-09-05-build-comment-consolidation.md#krfb-shipped-disabled-to-avoid-pinning-a-gpu-awake
#
# Use the canonical unit name. pvermeer's package also ships a sunshine.service
# compat symlink, but upstream only declares it as an [Install] Alias= — which
# doesn't exist until the real unit is enabled, so enabling the alias fails.
systemctl --global enable app-dev.lizardbyte.app.Sunshine.service

### SELinux boolean for containerized GPU compute
# Enabled even though the lemonade Quadlet is deliberately not — without it, ROCm dies
# with an HSA abort that looks nothing like a permission error. Guarded and idempotent,
# so it's a no-op on every boot after the first. See lemonade.sh.
systemctl enable lemonade-selinux.service

### Linger for rootless user services
# All three LLM stacks (lemonade.container, vllm.container, llamafactory.container) are rootless
# user units. Without linger, systemd tears the user manager down at logout and takes a running
# server with it — including a server started over SSH, the moment that SSH session ends. That
# is a genuine trap on a headless-ish box: the model unloads mid-request for no visible reason.
#
# `loginctl enable-linger` records this as a file under /var/lib/systemd/linger/<user>.
# /var is machine-local state on a bootc system, NOT part of the image, so this cannot be
# baked as a file — it has to be (re)asserted at boot, which is what the oneshot below
# does. That also makes it survive a wipe-and-rebase, which a manual `loginctl` call would
# not.
#
# Deliberately does NOT auto-start anything: none of the three .container files has an
# [Install] section, so a lingering user manager still starts no LLM at boot. This only keeps
# a HAND-STARTED one alive past logout — which matters most for llamafactory, whose whole point
# is a run that outlives the SSH session that launched it.
#
# Defined here rather than in lemonade.sh/vllm.sh/llamafactory.sh because it serves all of them
# and belongs to none. Enumerates users instead of hardcoding a name so it keeps working whatever
# the account is called after a reinstall.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-enable-linger << 'EOF'
#!/bin/bash
# Enable systemd linger for every regular login user. Idempotent; safe to re-run at boot.
set -euo pipefail

while IFS=: read -r name _ uid _ _ home shell; do
    # Regular human accounts only: skip system users and nobody (65534).
    if [ "$uid" -lt 1000 ] || [ "$uid" -ge 60000 ]; then
        continue
    fi
    case "$shell" in
        */nologin | */false | "") continue ;;
    esac
    if [ ! -d "$home" ]; then
        continue
    fi
    if [ -e "/var/lib/systemd/linger/$name" ]; then
        continue
    fi
    # Non-fatal: one bad account must not fail the unit for the others.
    loginctl enable-linger "$name" || echo "kinoite-enable-linger: failed for $name" >&2
done < /etc/passwd
EOF
bash -n /usr/libexec/kinoite-enable-linger

cat > /usr/lib/systemd/system/kinoite-linger.service << 'EOF'
[Unit]
Description=Enable systemd linger for regular login users
Documentation=file:///usr/share/kinoite/vllm.md
After=systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-enable-linger
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable kinoite-linger.service


### Suspend/resume for the LLM stacks
# Stops whichever LLM stack is running before the box sleeps and starts back exactly what was
# running on resume. Load-bearing, not a power tweak: amdgpu evicts VRAM into system RAM to
# suspend, a loaded vLLM holds ~28 GiB on each R9700, and this box has 64 GB of RAM. Suspending
# with a model loaded does not fail gracefully — it hangs the machine hard enough to need the
# power button, with an empty kernel log. See docs/explanation/suspend-and-wake.md.
#
# A TRAINING run is the same hazard from the other direction: llamafactory holds weights,
# gradients and optimiser state, which is why llamafactory.service joins the lists below.
#
# wol.sh rejects sleep hooks on principle where a declarative alternative exists. There isn't one
# here: nothing in podman, systemd or amdgpu expresses "stop this rootless user unit before the
# kernel sleeps".
#
# Sleep hook: system unit, not user (user manager has no sleep target) and not a
# /usr/lib/systemd/system-sleep/ drop-in (freezes user.slice). Full rationale:
# docs/runs/2026-09-05-build-comment-consolidation.md#sleep-hook-two-rejected-shapes
#
# Serves all three LLM stacks, so kinoite-* and defined here — same rationale as linger above.
# Depends on kinoite-linger.service for /run/user/<uid>/bus; mask that and this silently no-ops.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-llm-sleep << 'EOF'
#!/bin/bash
# Stop the GPU-holding LLM stacks before sleep; restore them after. `pre` from the unit's
# ExecStart, `post` from its ExecStop.
#
# NO `set -e`, deliberately. systemd runs ExecStop only for a service that started successfully
# (systemd.service(5)). A nonzero exit from `pre` would therefore not just leave VRAM held — it
# would put the unit in `failed` and silently cancel the restore on resume. Everything fallible is
# guarded by hand and the script always exits 0.
set -uo pipefail

# runuser inherits the caller's cwd, which need not be readable by the target user — from
# /var/roothome a child like podman dies with "cannot chdir". The unit already runs at /; this
# makes a hand-run behave the same.
cd / || exit 0

STATE_DIR=/run/kinoite-llm-sleep

# Stopped in ONE transaction, pod first: Quadlet gives each member BindsTo=north-llm-pod.service,
# so systemd sequences the teardown. A per-unit loop would also let a future Upholds= on the pod
# restart a member mid-teardown.
#
# llamafactory.service is here for the same reason the inference stacks are, not as an
# afterthought: a training run holds VRAM on BOTH R9700s (optimiser state and activations, not
# just weights), and that is exactly the condition that hangs this box on suspend.
# See llamafactory.sh.
STOP_UNITS=(north-llm-pod.service vllm.service open-webui.service lemonade.service llamafactory.service)

# Restore goes through MEMBERS, never the pod: the pod's Wants= would start both members
# unconditionally, losing the point of recording what was actually up.
#
# Restoring llamafactory brings back the SERVER (LLaMA Board/Jupyter), not an in-flight training
# run — that process was killed with the container and its unsaved progress is gone. For a long
# fine-tune, hold the box awake instead: `systemd-inhibit --what=sleep --why='fine-tune' sleep inf`
# (or just don't let it idle-suspend). Documented in /usr/share/kinoite/llamafactory.md.
RESTORE_UNITS=(vllm.service open-webui.service lemonade.service llamafactory.service)

# Above any plausible desktop (idle is tens of MiB per card, more when a dGPU drives the display)
# and far below the ~28 GiB/card a loaded model holds. Only ever logged, never enforced.
VRAM_IDLE_MAX=$((4 * 1024 * 1024 * 1024))
VRAM_SETTLE_SECS=15

# Bound each bus call so systemd never has to kill ExecStart — see the no-`set -e` note for why a
# failed ExecStart is worse than a slow one.
UCTL_TIMEOUT=120

log()  { printf 'kinoite-llm-sleep: %s\n' "$*"; }
warn() { printf 'kinoite-llm-sleep: %s\n' "$*" >&2; }

# Drive a user's systemd manager from this root-owned system unit.
#
# NOT `systemctl --user --machine=<user>@.host`, which systemctl(1) documents for exactly this and
# which does not work on this image: sd-bus implements it by spawning a transient system unit
# running systemd-stdio-bridge, and that spawn fails with "Connection reset by peer". Root
# exporting XDG_RUNTIME_DIR and calling `systemctl --user` directly is refused too. Don't switch
# back without re-testing.
uctl() {
    local user=$1 uid=$2
    shift 2
    timeout "$UCTL_TIMEOUT" runuser -u "$user" -- env \
        "XDG_RUNTIME_DIR=/run/user/$uid" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
        systemctl --user "$@"
}

# Run $1 as `$1 <name> <uid>` for every user with a live user manager. Walks /run/user rather than
# /etc/passwd because the question here is "who has a session bus right now", and
# /run/user/<uid>/bus is exactly that predicate — unlike the passwd walk in kinoite-enable-linger,
# which answers the different, static question of who should linger.
for_each_user() {
    local runtime uid entry name
    for runtime in /run/user/*; do
        [ -d "$runtime" ] || continue
        uid=${runtime##*/}
        case $uid in '' | *[!0-9]*) continue ;; esac
        if [ "$uid" -lt 1000 ] || [ "$uid" -ge 60000 ]; then
            continue
        fi
        [ -S "$runtime/bus" ] || continue
        # No pipe: `getent | cut` is a pipefail footgun for nothing.
        entry=$(getent passwd "$uid" 2>/dev/null) || continue
        name=${entry%%:*}
        [ -n "$name" ] || continue
        # Non-fatal per user: one broken account must not cost the others their restore.
        "$1" "$name" "$uid" || warn "$1 failed for $name (uid $uid)"
    done
}

suspend_user() {
    local name=$1 uid=$2 unit i
    local -a active=() restore=() states=()

    # One is-active call for the whole list: it prints a line per unit in argument order (units the
    # generator never produced come back "inactive"), which is what makes the index alignment safe.
    # Each uctl call is a runuser PAM session pair in the journal, so fewer is better. The exit
    # status is discarded — it is nonzero whenever any unit is inactive, i.e. normally.
    mapfile -t states < <(uctl "$name" "$uid" is-active "${STOP_UNITS[@]}" 2>/dev/null) || true

    for i in "${!STOP_UNITS[@]}"; do
        [ "${states[i]-}" = active ] || continue
        unit=${STOP_UNITS[i]}
        active+=("$unit")
        case " ${RESTORE_UNITS[*]} " in
            *" $unit "*) restore+=("$unit") ;;
        esac
    done

    # Written before anything is stopped, and even when empty — its presence is the proof that
    # `pre` ran for this user. /run is tmpfs on purpose: these Quadlets have no [Install] so that
    # nothing starts an LLM at boot, and a state file surviving a reboot would undo that.
    if [ ${#restore[@]} -gt 0 ]; then
        printf '%s\n' "${restore[@]}" > "$STATE_DIR/$uid"
    else
        : > "$STATE_DIR/$uid"
    fi || warn "$name: cannot write $STATE_DIR/$uid; nothing will be restored"

    if [ ${#active[@]} -eq 0 ]; then
        log "$name: no LLM units active, nothing to stop"
        return 0
    fi

    log "$name: stopping ${active[*]} (will restore: ${restore[*]:-none})"
    # Only units confirmed active: `stop` on a unit the generator never produced exits 5.
    uctl "$name" "$uid" stop "${active[@]}" \
        || warn "$name: stop returned nonzero; units may still be up"

    # The difference between "we asked" and "it happened".
    states=()
    mapfile -t states < <(uctl "$name" "$uid" is-active "${active[@]}" 2>/dev/null) || true
    for i in "${!active[@]}"; do
        if [ "${states[i]-}" = active ]; then
            warn "$name: ${active[i]} STILL ACTIVE after stop — its VRAM will still be held"
        fi
    done
}

resume_user() {
    local name=$1 uid=$2 file unit
    local -a restore=()
    file=$STATE_DIR/$uid
    [ -f "$file" ] || return 0

    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        restore+=("$unit")
    done < "$file"

    # Consumed before starting, so a second `post` cannot re-issue the starts.
    rm -f "$file"

    if [ ${#restore[@]} -eq 0 ]; then
        log "$name: nothing was running before the sleep"
        return 0
    fi

    # --no-block is required, not an optimisation: vllm.container sets TimeoutStartSec=3600 for the
    # model load, so waiting here would park ExecStop until our own TimeoutStopSec killed it,
    # failing the unit on every resume. Cost: we learn the job was accepted, not that the server
    # came up — `journalctl --user -u vllm -f` for that.
    log "$name: restoring ${restore[*]} (--no-block; the model needs 1-2 min)"
    uctl "$name" "$uid" start --no-block "${restore[@]}" \
        || warn "$name: could not enqueue start for ${restore[*]}"
}

# Log every amdgpu card's VRAM after the stop. Never fails the script (a nonzero exit would cancel
# the restore). This is the only trace that would survive the failure it watches for: suspending
# with VRAM still held hangs the box with an empty log.
vram_settle() {
    local deadline f card used worst report
    deadline=$((SECONDS + VRAM_SETTLE_SECS))
    while :; do
        worst=0
        report=''
        for f in /sys/class/drm/card*/device/mem_info_vram_used; do
            [ -r "$f" ] || continue
            card=${f#/sys/class/drm/}
            card=${card%%/*}
            # Per-connector dirs (card1-DP-1) point at the same pci node. They do not currently
            # expose this file, so this is a guard against silently double-counting, not a fix.
            case $card in *-*) continue ;; esac
            used=''
            read -r used < "$f" || continue
            case $used in '' | *[!0-9]*) continue ;; esac
            report="$report $card=$((used / 1024 / 1024))MiB"
            if [ "$used" -gt "$worst" ]; then
                worst=$used
            fi
        done
        if [ "$worst" -le "$VRAM_IDLE_MAX" ] || [ "$SECONDS" -ge "$deadline" ]; then
            break
        fi
        sleep 0.5
    done

    if [ -z "$report" ]; then
        warn "no readable mem_info_vram_used under /sys/class/drm — VRAM not verified"
    elif [ "$worst" -gt "$VRAM_IDLE_MAX" ]; then
        warn "VRAM still held after ${VRAM_SETTLE_SECS}s:${report} — suspend proceeds anyway."
        warn "If the box then hangs at 'PM: suspend entry' and needs a power cycle, this is why."
    else
        log "VRAM settled:${report}"
    fi
}

case "${1-}" in
    pre)
        mkdir -p "$STATE_DIR" || { warn "cannot create $STATE_DIR"; exit 0; }
        for_each_user suspend_user
        vram_settle
        ;;
    post)
        # ExecStop fires whenever the unit deactivates. DefaultDependencies=no keeps shutdown from
        # being one of those moments; this covers anything else that stops the unit at the wrong
        # time, since "restore" here means starting multi-gigabyte GPU workloads.
        if [ "$(systemctl is-system-running 2>/dev/null || true)" = stopping ]; then
            log "system is shutting down; not restoring anything"
            exit 0
        fi
        UCTL_TIMEOUT=30   # `post` only enqueues jobs; nothing here should take long
        for_each_user resume_user
        ;;
    *)
        # argv is fixed by the unit, so this can only be a human. Safe to exit nonzero here only.
        warn "usage: ${0##*/} pre|post"
        exit 2
        ;;
esac

exit 0
EOF
bash -n /usr/libexec/kinoite-llm-sleep

cat > /usr/lib/systemd/system/kinoite-llm-sleep.service << 'EOF'
[Unit]
Description=Stop GPU-holding LLM stacks across suspend, restore them on resume
Documentation=file:///usr/share/kinoite/vllm.md
Documentation=file:///usr/share/kinoite/lemonade.md
Documentation=file:///usr/share/kinoite/llamafactory.md

# All four sleep services (suspend, hibernate, hybrid-sleep, suspend-then-hibernate) declare
# Requires=sleep.target, so this one hook covers every flavour.
Before=sleep.target

# Not for ordering — the default deps are satisfied long before any sleep. It is the implicit
# Conflicts=shutdown.target: this unit's ExecStop means "start several GPU workloads", and that
# must not be triggered by a shutdown.
DefaultDependencies=no

# What produces the resume-side ExecStop: sleep.target is itself StopWhenUnneeded and goes away
# after systemd-suspend.service finishes, leaving this unit with no referrer. This is a [Unit] key
# — under [Service] systemd ignores it with only a log line and the restore silently never runs.
StopWhenUnneeded=yes

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-llm-sleep pre
ExecStop=/usr/libexec/kinoite-llm-sleep post

# Without RemainAfterExit a oneshot goes inactive as soon as ExecStart returns, so there is
# nothing left to stop and ExecStop never runs.
RemainAfterExit=yes

# Backstops only; the helper bounds its own bus calls so systemd never has to kill it.
TimeoutStartSec=300
TimeoutStopSec=180

[Install]
# RequiredBy, not WantedBy: with a soft Wants= a failed hook would let the suspend proceed anyway,
# into a hang that needs the power button. Requiring it means a failed hook refuses the suspend
# and leaves the box awake with something to look at.
#
# So opt out with `systemctl disable`, NOT `mask` — masking leaves sleep.target requiring a masked
# unit, which makes the box unable to suspend at all.
RequiredBy=sleep.target
EOF

# Unit-file gate, the [Unit]-vs-[Service] counterpart to `bash -n`. Greps for the misplaced-key
# class rather than trusting the exit status, which also trips on units absent in a build
# container. A key in the wrong section is accepted silently by systemd and breaks the restore.
if command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze verify /usr/lib/systemd/system/kinoite-llm-sleep.service 2>&1 \
        | grep -E 'Unknown key name|Unknown section'; then
        echo "services-north.sh: bad key in kinoite-llm-sleep.service (see above)" >&2
        exit 1
    fi
fi

systemctl enable kinoite-llm-sleep.service
