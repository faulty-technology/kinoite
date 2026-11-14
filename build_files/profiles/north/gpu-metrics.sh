#!/bin/bash
set -ouex pipefail

# gpu-metrics: per-card AMD GPU gauges for the two R9700s, written into Alloy's textfile
# directory so host.alloy's prometheus.exporter.unix serves them as north_gpu_*.
#
# The gate: every amdgpu hwmon read calls pm_runtime_get_sync() and wakes the card
# (docs/how-to/measure-gpu-idle.md). So runtime_status is read FIRST, passively, and the
# detailed metrics are emitted only for a card that is already active. A suspended card
# yields north_gpu_awake=0 and nothing else — the dashboard renders "suspended", not zero.
# docs/decisions/2026-11-14-north-gpu-metrics.md.

### 1. Script
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-gpu-metrics << 'EOF'
#!/bin/bash
set -euo pipefail

OUT_DIR=/var/lib/alloy/textfile
OUT="$OUT_DIR/amdgpu.prom"
TMP="$OUT.tmp"
mkdir -p "$OUT_DIR"

# Radeon AI PRO R9700 (gfx1201). The 610M iGPU is pinned power/control=on by the display
# manager and reports desktop compositing, not LLM workload — excluded on purpose.
CHIP_ID=1002:7551

# $1 metric line prefix (name + labels), $2 sysfs file, $3 optional divisor.
# Emits nothing for a missing or non-numeric source rather than a fake zero.
metric() {
    local v
    [ -f "$2" ] || return 0
    v=$(cat "$2" 2>/dev/null) || return 0
    case "$v" in ''|*[!0-9.-]*) return 0 ;; esac
    if [ -n "${3:-}" ]; then
        printf '%s %s\n' "$1" "$(awk -v v="$v" -v s="$3" 'BEGIN { printf "%g", v / s }')"
    else
        printf '%s %s\n' "$1" "$v"
    fi
}

{
    echo "# TYPE north_gpu_awake gauge"
    echo "# TYPE north_gpu_power_control gauge"
    echo "# TYPE north_gpu_busy_percent gauge"
    echo "# TYPE north_gpu_vram_used_bytes bytes"
    echo "# TYPE north_gpu_vram_total_bytes bytes"
    echo "# TYPE north_gpu_temp_celsius celsius"
    echo "# TYPE north_gpu_power_watts watts"
    echo "# TYPE north_gpu_power_cap_watts watts"
    echo "# TYPE north_gpu_fan_rpm rpm"
    echo "# TYPE north_gpu_sclk_mhz gauge"
    echo "# TYPE north_gpu_mclk_mhz gauge"
} > "$TMP"

for dev in /sys/class/drm/card[0-9]*/device; do
    [ -f "$dev/gpu_busy_percent" ] || continue
    [ "$(awk -F= '/^PCI_ID=/{print $2}' "$dev/uevent")" = "$CHIP_ID" ] || continue
    pci=$(awk -F= '/^PCI_SLOT_NAME=/{print $2}' "$dev/uevent")

    # Passive first: runtime_status and power/control never wake the card.
    status=$(cat "$dev/power/runtime_status")
    control=$(cat "$dev/power/control")
    if [ "$status" = "active" ]; then awake=1; else awake=0; fi

    {
        echo "north_gpu_awake{pci=\"$pci\"} $awake"
        echo "north_gpu_power_control{pci=\"$pci\",mode=\"$control\"} 1"
    } >> "$TMP"

    # The gate: nothing below may run on a suspended card. power1_cap would return EBUSY
    # anyway, and every other read here wakes the device.
    [ "$status" = "active" ] || continue

    hw=$(ls -d "$dev"/hwmon/hwmon* | head -n1)

    # Clocks: this kernel exposes the DPM clocks as hwmon freq channels, not pp_dpm_*.
    # Pick the channel by its label (freq1=sclk, freq2=mclk on gfx1201).
    sclk="" mclk=""
    for i in 1 2; do
        [ -f "$hw/freq${i}_label" ] || continue
        case "$(cat "$hw/freq${i}_label")" in
            sclk) sclk="$hw/freq${i}_input" ;;
            mclk) mclk="$hw/freq${i}_input" ;;
        esac
    done

    {
        metric "north_gpu_busy_percent{pci=\"$pci\"}" "$dev/gpu_busy_percent"
        metric "north_gpu_vram_used_bytes{pci=\"$pci\"}" "$dev/mem_info_vram_used"
        metric "north_gpu_vram_total_bytes{pci=\"$pci\"}" "$dev/mem_info_vram_total"
        # temp1_input is millidegrees; power1_* are microwatts.
        metric "north_gpu_temp_celsius{pci=\"$pci\"}" "$hw/temp1_input" 1000
        metric "north_gpu_power_watts{pci=\"$pci\"}" "$hw/power1_average" 1000000
        metric "north_gpu_power_cap_watts{pci=\"$pci\"}" "$hw/power1_cap" 1000000
        metric "north_gpu_fan_rpm{pci=\"$pci\"}" "$hw/fan1_input"
        if [ -n "$sclk" ]; then metric "north_gpu_sclk_mhz{pci=\"$pci\"}" "$sclk" 1000000; fi
        if [ -n "$mclk" ]; then metric "north_gpu_mclk_mhz{pci=\"$pci\"}" "$mclk" 1000000; fi
    } >> "$TMP"
done

# A dead timer shows up as a stale gauge, not silently missing data.
echo "north_gpu_metrics_last_run_timestamp_seconds $(date +%s)" >> "$TMP"

# Atomic: Alloy must never read a half-written file.
mv "$TMP" "$OUT"
EOF

### 2. Units
cat > /usr/lib/systemd/system/kinoite-gpu-metrics.service << 'EOF'
[Unit]
Description=Emit R9700 GPU gauges to the Alloy textfile directory (runtime_status-gated)

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-gpu-metrics
TimeoutStartSec=30
EOF

cat > /usr/lib/systemd/system/kinoite-gpu-metrics.timer << 'EOF'
[Unit]
Description=Periodic R9700 GPU gauges for the Alloy textfile collector

[Timer]
OnBootSec=60s
OnUnitActiveSec=15s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

# Unit-file gate, same shape as tuning.sh: a key in the wrong section is accepted
# silently by systemd.
if command -v systemd-analyze >/dev/null 2>&1; then
    for u in kinoite-gpu-metrics.service kinoite-gpu-metrics.timer; do
        if systemd-analyze verify "/usr/lib/systemd/system/$u" 2>&1 \
            | grep -E 'Unknown key name|Unknown section'; then
            echo "gpu-metrics.sh: bad key in $u (see above)" >&2
            exit 1
        fi
    done
fi

systemctl enable kinoite-gpu-metrics.timer
