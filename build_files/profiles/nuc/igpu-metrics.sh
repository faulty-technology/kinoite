#!/bin/bash
set -ouex pipefail

# igpu-metrics: i915 frequency gauges for the NUC's Iris Xe, written into node-exporter's
# textfile directory (the in-cluster DaemonSet gets --collector.textfile.directory from the
# homelab repo). No busyness metric in phase 1: intel_gpu_top -J needs CAP_PERFMON + /dev/dri.
# No power channel either — i915 exposes no hwmon power attribute on this board, and a fake
# zero would be worse than an absent series.

### 1. Script
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-igpu-metrics << 'EOF'
#!/bin/bash
set -euo pipefail

OUT_DIR=/var/lib/node_exporter/textfile
OUT="$OUT_DIR/igpu.prom"
TMP="$OUT.tmp"
install -d -m 0755 "$OUT_DIR"

# Find the i915 card by its gt_ attributes, not by card index (enumeration is not stable).
dev=""
for c in /sys/class/drm/card[0-9]*/gt_cur_freq_mhz; do
    dev=$(dirname "$c")
    break
done
[ -n "$dev" ] || exit 0

{
    echo "# TYPE nuc_igpu_cur_freq_mhz gauge"
    echo "# TYPE nuc_igpu_act_freq_mhz gauge"
    echo "# TYPE nuc_igpu_max_freq_mhz gauge"
    echo "# TYPE nuc_igpu_min_freq_mhz gauge"
    echo "# TYPE nuc_igpu_rp0_freq_mhz gauge"
    echo "# TYPE nuc_igpu_rp1_freq_mhz gauge"
    echo "# TYPE nuc_igpu_rpn_freq_mhz gauge"
    echo "# TYPE nuc_igpu_boost_freq_mhz gauge"
} > "$TMP"

# $1 metric name, $2 attribute suffix (gt_<suffix>_freq_mhz). Emits nothing when the
# kernel does not expose the attribute.
metric() {
    local f="$dev/${2}_freq_mhz" v
    [ -f "$f" ] || return 0
    v=$(cat "$f" 2>/dev/null) || return 0
    case "$v" in ''|*[!0-9.-]*) return 0 ;; esac
    printf '%s %s\n' "$1" "$v"
}

{
    metric "nuc_igpu_cur_freq_mhz"   gt_cur
    metric "nuc_igpu_act_freq_mhz"   gt_act
    metric "nuc_igpu_max_freq_mhz"   gt_max
    metric "nuc_igpu_min_freq_mhz"   gt_min
    metric "nuc_igpu_rp0_freq_mhz"   gt_RP0
    metric "nuc_igpu_rp1_freq_mhz"   gt_RP1
    metric "nuc_igpu_rpn_freq_mhz"   gt_RPn
    metric "nuc_igpu_boost_freq_mhz" gt_boost
} >> "$TMP"

# A dead timer shows up as a stale gauge, not silently missing data.
echo "nuc_igpu_metrics_last_run_timestamp_seconds $(date +%s)" >> "$TMP"

# Atomic: node-exporter must never read a half-written file.
mv "$TMP" "$OUT"
EOF

### 2. Units
cat > /usr/lib/systemd/system/kinoite-igpu-metrics.service << 'EOF'
[Unit]
Description=Emit i915 frequency gauges to the node-exporter textfile directory

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-igpu-metrics
RemainAfterExit=yes
TimeoutStartSec=30
EOF

cat > /usr/lib/systemd/system/kinoite-igpu-metrics.timer << 'EOF'
[Unit]
Description=Periodic i915 frequency gauges for the node-exporter textfile collector

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
    for u in kinoite-igpu-metrics.service kinoite-igpu-metrics.timer; do
        if systemd-analyze verify "/usr/lib/systemd/system/$u" 2>&1 \
            | grep -E 'Unknown key name|Unknown section'; then
            echo "igpu-metrics.sh: bad key in $u (see above)" >&2
            exit 1
        fi
    done
fi
