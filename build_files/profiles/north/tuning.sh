#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

# AMD 9900X (Zen 5) + dual R9700 (RDNA4) tunings for a gaming + local-LLM box.

### 1. vm.max_map_count
# Fedora's default (1048576) is fine for most workloads, but the SteamOS value
# fixes a class of Proton games that hang/crash on the lower limit and also helps
# memory-mapped model loading in LLM runtimes (large mmap counts). No downside.
cat > /usr/lib/sysctl.d/99-north.conf << 'EOF'
vm.max_map_count=2147483642
EOF

### 2. amdgpu powerplay controls (baked kernel arg)
# Unlocks OverDrive so clock and voltage offsets are adjustable (e.g. via LACT
# below). Still required on RDNA4 — this is not a legacy Vega/Navi1 thing. Power
# caps (`power1_cap`) work without it; the offsets don't.
#
# 0xfff7ffff, not the 0xffffffff every guide repeats: the driver default is
# 0xfff7bfff and OverDrive is PP_OVERDRIVE_MASK (0x4000), so this is exactly
# "default + OverDrive". 0xffffffff would additionally set PP_GFX_DCS_MASK
# (0x80000), which the driver deliberately leaves off, plus every reserved bit.
# Re-derive from amd_shared.h if a kernel bump changes the default.
#
# THIS FILE ALONE IS NOT ENOUGH, and the way it fails is silent. kargs.d is a
# *bootc* mechanism: only `bootc install`/`switch`/`upgrade` read it, and
# `rpm-ostree rebase`/`upgrade` ignores the directory entirely. That is not the
# whole story here, though — this box updates with `bootc upgrade` (its timer
# enabled since 2026-03-04, `rpm-ostreed-automatic.timer` masked) and all three
# entries were added 2026-08-08 through 2026-08-23, months later, yet they still
# did not all apply. The mechanism is unexplained: verify against /proc/cmdline
# rather than trusting the directory.
#
# Measured on the box 2026-08-23: all three kargs.d entries present in /usr,
# only `split_lock_detect=off` on /proc/cmdline. Re-measured 2026-08-24:
# `acpi_enforce_resources=lax` still absent from the booted *and* staged
# deployments, so it is not waiting on a reboot. With OverDrive locked there is
# no `pp_od_clk_voltage` and no `gpu_od/` at all, so LACT's voltage offset
# cannot apply — it logs "custom clock settings are present but will be ignored"
# at ERROR, once per card, and carries on. The undervolt had never once run.
#
# RESOLVED on this box as of 2026-08-25: the `rpm-ostree kargs` fix below has been
# applied, `amdgpu.ppfeaturemask=0xfff7ffff` is on /proc/cmdline, and
# `gpu_od/fan_ctrl/fan_curve` now exists on both cards (reading `0C 0%` x5, i.e.
# present and unset). So the two OD-gated knobs in section 4 are live rather than
# silently discarded, and a fan curve written there demonstrably applies — verified
# by writing one and watching hotspot fall 18C. The paragraph above is kept because
# it describes the DEFAULT state of a freshly-installed box, which is still locked:
# treat it as the thing to check first, not as a description of this machine.
#
# Fix, once per machine — this writes the karg into the ostree deployment, where
# it persists across updates whichever tool drives them:
#     rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff && systemctl reboot
# kinoite-gpu-tune.service (section 3) asserts this at boot so it cannot go
# quiet again. Keep the file below regardless: it is still what makes a fresh
# `bootc install` come up correct.
mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/10-amdgpu.toml << 'EOF'
kargs = ["amdgpu.ppfeaturemask=0xfff7ffff"]
match-architectures = ["x86_64"]
EOF

### 3. LACT — Linux AMDGPU Control Tool (installed as the tuning GUI, daemon off)
# Uses the powerplay controls unlocked above. Installed from the maintainer's
# COPR, key fingerprint-pinned like the other third-party sources.
add_copr ilyaz-lact ilyaz/LACT DC70DFEA1822B0720140518FA3BA601174A6903B

install_pkgs lact

# Deliberately NOT enabled. LACT is kept as the interactive GUI for tuning
# experiments; section 4 owns what actually gets applied at boot.
#
# Two measured reasons, both 2026-08-23, both in notes/:
#   - LACT reverts the power cap when it stops. `systemctl stop lactd` puts
#     `power1_cap` straight back to 300 W. A setting LACT owns only holds for as
#     long as LACT is resident, which makes it the wrong place for a boot-time
#     tuning that should survive anything short of a reboot.
#   - Nothing it can apply is worth a resident daemon here. Only `power1_cap`
#     survives a runtime suspend/resume at all, and section 4 writes that in one
#     sysfs write with no daemon.
#
# What is NOT a reason any more: holding the dGPUs awake. That was true of the
# version measured earlier and is fixed as of 0.10.0 (upstream #828 / PR #836) —
# 100 s resident with both cards at `runtime_status=suspended` throughout. If a
# future bump regresses it, that is a re-test, not an assumption.
#
# Start it by hand when you want the GUI: `sudo systemctl start lactd`. Note it
# will then apply whatever is in /etc/lact/config.yaml on top of section 4.
systemctl disable lactd.service 2>/dev/null || true

### 4. Baked GPU tunings — power cap, optional undervolt and fan curve
# Everything here is a plain sysfs write. LACT is not in the path, and neither is
# amd-smi: `amd-smi set` has no voltage-offset argument at all, its `--fan` needs
# the `pwm1_enable` this card lacks, and `amd-smi metric` *dumps core* on gfx1201
# because it cannot parse `OD_SCLK_OFFSET`. See notes/ for the assertion.
#
# DURABILITY IS NOT UNIFORM, and this is the whole reason the script looks the way
# it does. Measured by hand with lactd stopped:
#   power1_cap      survives a runtime suspend/resume cycle       -> set once, sticks
#   voltage offset  wiped to 0mV on every D3->D0 transition       -> ~10 s of idle
#   fan curve       wiped to `0C 0%` on every D3->D0 transition   -> same OD table
# So only the power cap is genuinely "apply at boot and forget". The other two are
# shipped unset, with the knobs present and documented, because maintaining them
# would mean re-applying every time a card wakes for a workload.
#
# WHAT THE FAN CURVE IS ACTUALLY FOR, measured under vLLM load 2026-08-25. It is a
# thermal and efficiency knob and NOT a performance one. Under a sustained 27B decode
# the stock firmware curve is far too quiet — it settles at 88-93C hotspot with the
# fans at 33-39% PWM — and at that temperature the cards leak enough extra current to
# sit pinned against the 235 W cap below, which clamps sclk to ~2360 MHz against a
# ~3360 MHz ceiling. Writing `FAN_CURVE="45:40 55:55 65:70 75:85 85:100"` at an
# unchanged cap moved all of it:
#     hotspot 88-93C -> 70-78C | power 234/235W -> 184-203W | sclk ~2360 -> ~3370MHz
# ...and changed vLLM throughput by -0.1%, i.e. not at all, because batch-1 decode is
# memory-bandwidth bound and mclk never left top DPM either way. See the "GPU clocks
# and thermals" dead end in vllm.md for the A/B.
#
# So: worth applying for ~18C and ~90 W across the pair, and worth knowing that a
# THROTTLED flag here costs nothing in tok/s. That curve is deliberately aggressive
# (it pins the fans near 100% at these temperatures) because it was built to remove
# thermals as a variable for the A/B; something like
# `FAN_CURVE="50:35 65:45 75:60 85:80 95:100"` lands ~80C at far lower RPM for daily
# use. Still shipped unset for the D3->D0 reason above — a baked default would
# silently evaporate ~10 s after the cards go idle, which is worse than not having one.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-gpu-tune << 'EOF'
#!/bin/bash
# Apply the baked AMD GPU tunings to the discrete cards. `apply` from the unit's
# ExecStart; `status` for a human.
#
# NO `set -e`. One unwritable node on one card must not cost the other card its settings,
# and a missing karg must not turn into a failed unit at boot. Everything fallible is
# guarded by hand; `apply` always exits 0.
set -uo pipefail

# --- defaults; override in /etc/kinoite/gpu-tune.conf --------------------------------
# Watts. Empty leaves the card at its default cap.
POWER_CAP_W=235
# Millivolts, negative for an undervolt (e.g. -50). Empty leaves it alone.
# NOTE: wiped on every idle cycle. See the durability table in tuning.sh.
VOLTAGE_OFFSET_MV=
# Exactly five "hotspotC:speed%" points, e.g. "40:30 50:40 60:55 70:75 80:100".
# Ranges are 25-100C and 30-100%. Empty leaves the firmware curve alone.
# NOTE: wiped on every idle cycle, same as the offset.
FAN_CURVE=
# -------------------------------------------------------------------------------------

CONF=/etc/kinoite/gpu-tune.conf
if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF" || echo "kinoite-gpu-tune: $CONF failed to parse; using built-in defaults" >&2
fi

log()  { printf 'kinoite-gpu-tune: %s
' "$*"; }
warn() { printf 'kinoite-gpu-tune: %s
' "$*" >&2; }

# Discrete AMD GPUs, by PCI address. The predicate is "amdgpu device whose hwmon exposes
# power1_cap" — the Raphael iGPU has a hwmon with power1_input only, so this selects the
# two R9700s without hardcoding 03:00.0/06:00.0 or trusting cardN numbering, which is not
# stable across boots. The node exists even while the card is runtime-suspended (reads
# return EBUSY rather than ENOENT), so enumeration never wakes anything.
dgpus() {
    local dev
    for dev in /sys/bus/pci/drivers/amdgpu/*:*:*.*; do
        [ -d "$dev" ] || continue
        compgen -G "$dev/hwmon/hwmon*/power1_cap" > /dev/null || continue
        printf '%s
' "$dev"
    done
}

# OverDrive gate. Without it there is no pp_od_clk_voltage and no gpu_od/ at all, and the
# failure is otherwise completely silent — which is exactly how the undervolt sat in
# /etc/lact/config.yaml for days without ever executing. The power cap does NOT need it.
od_unlocked() { grep -q 'amdgpu\.ppfeaturemask=' /proc/cmdline; }

# Every OD write needs the card in D0; on a suspended card they return EBUSY. Forcing
# power/control=on is the controlled way to guarantee that, and putting it back is
# mandatory — a stray `on` forbids runtime suspend for the life of the boot and is the
# single most expensive mistake in this area (hours of "it never suspends" that turned
# out to be measuring the pin). Hence the trap, which fires on the error paths too.
#
# Note this SETS `auto`, it does not restore a previous value: a card found at `on` is
# left at `auto` afterwards. That is deliberate — on this box a pinned dGPU is always a
# bug, never a policy — but it does mean the script quietly fixes one if it finds it.
RESTORE_CONTROL=()
restore_control() {
    local c
    for c in ${RESTORE_CONTROL+"${RESTORE_CONTROL[@]}"}; do
        echo auto > "$c" 2>/dev/null || warn "COULD NOT set $c back to auto — runtime suspend is pinned off"
    done
    RESTORE_CONTROL=()
}
trap restore_control EXIT INT TERM

wake() {
    local dev=$1
    [ -w "$dev/power/control" ] || return 1
    RESTORE_CONTROL+=("$dev/power/control")
    echo on > "$dev/power/control" 2>/dev/null || return 1
    # D3->D0 is not instant and an immediate write can still catch EBUSY.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(cat "$dev/power/runtime_status" 2>/dev/null)" = active ] && return 0
        sleep 0.2
    done
    return 1
}

apply_power_cap() {
    local dev=$1 name=$2 h uw max min
    [ -n "$POWER_CAP_W" ] || return 0
    for h in "$dev"/hwmon/hwmon*; do
        [ -w "$h/power1_cap" ] || continue
        uw=$((POWER_CAP_W * 1000000))
        # Clamp rather than let the kernel reject the whole write. Note the ceiling moves
        # with the ppfeaturemask karg: 300 W locked, 330 W with OverDrive unlocked.
        max=$(cat "$h/power1_cap_max" 2>/dev/null) || max=
        min=$(cat "$h/power1_cap_min" 2>/dev/null) || min=
        if [ -n "$max" ] && [ "$uw" -gt "$max" ]; then
            warn "$name: cap ${POWER_CAP_W}W above max $((max / 1000000))W; clamping"
            uw=$max
        fi
        if [ -n "$min" ] && [ "$uw" -lt "$min" ]; then
            warn "$name: cap ${POWER_CAP_W}W below min $((min / 1000000))W; clamping"
            uw=$min
        fi
        if echo "$uw" > "$h/power1_cap" 2>/dev/null; then
            log "$name: power cap $((uw / 1000000))W"
        else
            warn "$name: could not write power1_cap"
        fi
        return 0
    done
    warn "$name: no writable power1_cap"
}

apply_voltage_offset() {
    local dev=$1 name=$2 od=$dev/pp_od_clk_voltage
    [ -n "$VOLTAGE_OFFSET_MV" ] || return 0
    if [ ! -w "$od" ]; then
        warn "$name: no pp_od_clk_voltage; skipping voltage offset"
        return 1
    fi
    if ! echo "vo $VOLTAGE_OFFSET_MV" > "$od" 2>/dev/null; then
        warn "$name: staging voltage offset ${VOLTAGE_OFFSET_MV}mV failed (out of OD_RANGE?)"
        return 1
    fi
    if ! echo c > "$od" 2>/dev/null; then
        warn "$name: voltage offset commit rejected"
        return 1
    fi
    log "$name: voltage offset ${VOLTAGE_OFFSET_MV}mV (expect this to be gone after ~10 s of idle)"
}

reset_fan_curve() {
    local fc=$1
    echo r > "$fc" 2>/dev/null && echo c > "$fc" 2>/dev/null
}

apply_fan_curve() {
    local dev=$1 name=$2 fc=$dev/gpu_od/fan_ctrl/fan_curve
    [ -n "$FAN_CURVE" ] || return 0
    if [ ! -w "$fc" ]; then
        warn "$name: no gpu_od/fan_ctrl/fan_curve; skipping fan curve"
        return 1
    fi
    local -a pts
    read -r -a pts <<< "$FAN_CURVE"
    # The firmware validates the WHOLE curve at commit time, so a partial curve is not a
    # partial success: `c` returns EINVAL, the staged points still read back as if they
    # took, and the rejected commit then poisons the next commit on pp_od_clk_voltage
    # too. Refusing early is much kinder than discovering that later.
    if [ ${#pts[@]} -ne 5 ]; then
        warn "$name: FAN_CURVE needs exactly 5 points, got ${#pts[@]}; skipping"
        return 1
    fi
    local i t p
    for i in 0 1 2 3 4; do
        t=${pts[i]%%:*}
        p=${pts[i]##*:}
        if ! printf '%s %s %s
' "$i" "$t" "$p" > "$fc" 2>/dev/null; then
            warn "$name: staging fan curve point $i ($t C, $p %) failed; resetting curve"
            reset_fan_curve "$fc"
            return 1
        fi
    done
    if ! echo c > "$fc" 2>/dev/null; then
        warn "$name: fan curve commit rejected; resetting so it cannot poison the next OD commit"
        reset_fan_curve "$fc"
        return 1
    fi
    log "$name: fan curve ${FAN_CURVE} (expect this to be gone after ~10 s of idle)"
}

do_apply() {
    local dev name found=0

    if ! od_unlocked; then
        warn "amdgpu.ppfeaturemask is NOT on /proc/cmdline — OverDrive is locked."
        warn "The power cap still applies; the voltage offset and fan curve cannot."
        warn "kargs.d does not reliably deliver this karg — fix it once with:"
        warn "    rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff && systemctl reboot"
    fi

    for dev in $(dgpus); do
        found=1
        name=${dev##*/}
        if ! wake "$dev"; then
            warn "$name: could not bring the card to D0; settings may not take"
        fi
        apply_power_cap "$dev" "$name"
        # Voltage offset before fan curve: a rejected fan-curve commit leaves the OD table
        # in a state where the next pp_od_clk_voltage commit also fails.
        apply_voltage_offset "$dev" "$name"
        apply_fan_curve "$dev" "$name"
    done

    restore_control

    if [ "$found" -eq 0 ]; then
        warn "no discrete amdgpu found (no hwmon with power1_cap) — nothing to do"
    fi
}

do_status() {
    local dev name h
    printf 'OverDrive: %s
' "$(od_unlocked && echo unlocked || echo 'LOCKED (no ppfeaturemask karg)')"
    for dev in $(dgpus); do
        name=${dev##*/}
        # runtime_status FIRST and on its own: it is the one reading that cannot be
        # confounded by the act of reading. Everything below needs the card awake.
        printf '
%s  runtime_status=%s control=%s
'             "$name" "$(cat "$dev/power/runtime_status" 2>/dev/null)"             "$(cat "$dev/power/control" 2>/dev/null)"
        if ! wake "$dev"; then
            printf '  (could not wake; values unreadable — they return EBUSY in D3)
'
            continue
        fi
        for h in "$dev"/hwmon/hwmon*; do
            [ -r "$h/power1_cap" ] || continue
            printf '  power cap : %sW (max %sW)
'                 "$(($(cat "$h/power1_cap") / 1000000))" "$(($(cat "$h/power1_cap_max") / 1000000))"
            break
        done
        printf '  voltage   : %s
' "$(grep -A1 OD_VDDGFX_OFFSET "$dev/pp_od_clk_voltage" 2>/dev/null | tail -1 | tr -d ' 	' || echo n/a)"
        printf '  fan curve : %s
' "$(sed -n '2,6p' "$dev/gpu_od/fan_ctrl/fan_curve" 2>/dev/null | tr -s ' 
' ' ' || echo n/a)"
    done
    restore_control
}

case "${1-}" in
    apply)  do_apply ;;
    status) do_status ;;
    *)      warn "usage: ${0##*/} apply|status"; exit 2 ;;
esac

exit 0
EOF
bash -n /usr/libexec/kinoite-gpu-tune

### Documented example of the override file. Shipped under /usr/share rather than seeded
# into /etc so a rebase never has to 3-way-merge a file the box has edited; the script
# reads /etc/kinoite/gpu-tune.conf only if it exists.
install -D -m 0644 /dev/stdin /usr/share/kinoite/gpu-tune.conf.example << 'EOF'
# Overrides for kinoite-gpu-tune. Copy to /etc/kinoite/gpu-tune.conf and edit.
# Sourced as shell, so it is KEY=value with no spaces around the `=`.
# Apply with `sudo systemctl restart kinoite-gpu-tune`, inspect with
# `sudo /usr/libexec/kinoite-gpu-tune status`.

# Power cap in watts. THE ONLY SETTING HERE THAT SURVIVES AN IDLE CYCLE.
# Ceiling is 330 W with the ppfeaturemask karg applied, 300 W without it.
# Empty string leaves the card at its default.
POWER_CAP_W=235

# GPU voltage offset in millivolts, negative to undervolt. OD_RANGE is -200..0 mV.
#
# WIPED ON EVERY IDLE CYCLE — amdgpu drops the OverDrive table on each D3->D0
# transition, which happens ~10 s after the cards go quiet. Setting this here means
# "applied at boot and until the cards first idle", not "applied". It holds for a whole
# vLLM session only if re-applied once the model is loaded and the cards are pinned awake.
# Load-test before trusting any value: too aggressive makes the box unstable under load.
#VOLTAGE_OFFSET_MV=-50

# Fan curve: exactly five "hotspotC:speed%" points, ascending.
# Ranges are 25-100 C and 30-100 %.
#
# WIPED ON EVERY IDLE CYCLE, same as the offset. Also note 30 % is a hard firmware floor
# (`fan_minimum_pwm` will not go below 30, and 30 % of the 6500 RPM max is the ~1950 RPM
# "floor" you may have chased): a curve can only make an AWAKE card louder than that,
# never quieter. Letting the cards runtime-suspend is the only way below it.
#FAN_CURVE="40:30 50:40 60:55 70:75 80:100"
EOF

cat > /usr/lib/systemd/system/kinoite-gpu-tune.service << 'EOF'
[Unit]
Description=Apply baked AMD GPU tunings (power cap; optional undervolt and fan curve)
Documentation=file:///usr/share/kinoite/gpu-tune.conf.example

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-gpu-tune apply

# The work is a handful of sysfs writes that persist in the driver, so there is nothing to
# keep alive — but RemainAfterExit makes `systemctl status` say "active (exited)" rather
# than "inactive (dead)", which is the difference between "it ran" and "did it ever run?".
RemainAfterExit=yes

# Bounded purely as a backstop: the script waits at most ~2 s per card for D0.
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

# Unit-file gate, same shape as services-north.sh: a key in the wrong section is accepted
# silently by systemd. Greps rather than trusting the exit status, which also trips on
# units absent in a build container.
if command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze verify /usr/lib/systemd/system/kinoite-gpu-tune.service 2>&1 \
        | grep -E 'Unknown key name|Unknown section'; then
        echo "tuning.sh: bad key in kinoite-gpu-tune.service (see above)" >&2
        exit 1
    fi
fi

systemctl enable kinoite-gpu-tune.service
