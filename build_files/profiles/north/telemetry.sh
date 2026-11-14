#!/bin/bash
set -ouex pipefail

# telemetry: north's Alloy agent (build_files/scripts/alloy.sh) ships the journal to the nuc's
# OTel collector; this adds a scrape of radiance's Prometheus /metrics on loopback to the same
# pipeline. Why push from an agent rather than have the nuc scrape:
# docs/decisions/2026-11-14-north-telemetry-alloy-otlp.md.

SHARED="$(cd "$(dirname "$0")/../../scripts" && pwd)"

ALLOY_HOST=north ALLOY_ENDPOINT=http://nuc:31432 "$SHARED/alloy.sh"

# The radiance runbook is the on-box documentation for this agent.
sed -i '/^Documentation=https:\/\/grafana.com/a Documentation=file:///usr/share/kinoite/radiance.md' \
    /etc/containers/systemd/alloy.container

# All three radiance units share the port, so one target covers whichever is running; up == 0
# while none is. Feeds the batch processor defined in journal.alloy.
install -D -m 0644 /dev/stdin /etc/alloy/radiance.alloy << 'ALLOYEOF'
prometheus.scrape "radiance" {
  targets         = [{"__address__" = "127.0.0.1:8005", "instance" = "north"}]
  job_name        = "radiance"
  scrape_interval = "15s"
  scrape_timeout  = "10s"
  forward_to      = [otelcol.receiver.prometheus.default.receiver]
}

otelcol.receiver.prometheus "default" {
  output { metrics = [otelcol.processor.batch.default.input] }
}
ALLOYEOF

# Host telemetry: Alloy's built-in node_exporter fork reads the host through the read-only
# /host/* mounts alloy.sh bakes into the quadlet. Metric names are node_* so one query set
# serves both boxes (nuc scrapes its in-cluster node_exporter, north pushes this).
# docs/decisions/2026-11-14-north-host-metrics-alloy-unix-exporter.md.
#
# The exporter's default instance label is the container's hostname; discovery.relabel pins
# it to "north" so it matches the radiance convention above. No filesystem block: its only
# knobs are exclude regexes, and the defaults already drop every pseudo-fs north mounts
# (btrfs root + vfat EFI; /var is a subvolume of the same device).
install -d -m 0755 /var/lib/alloy/textfile

install -D -m 0644 /dev/stdin /etc/alloy/host.alloy << 'ALLOYEOF'
prometheus.exporter.unix "host" {
  procfs_path = "/host/proc"
  sysfs_path  = "/host/sys"
  rootfs_path = "/host/root"

  set_collectors = ["cpu", "cpufreq", "meminfo", "loadavg", "pressure",
                    "vmstat", "diskstats", "netdev", "filesystem",
                    "hwmon", "thermal_zone", "time", "uname", "textfile"]

  textfile { directory = "/var/lib/alloy/textfile" }
}

discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets

  rule {
    target_label = "instance"
    replacement  = "north"
  }
}

prometheus.scrape "host" {
  targets         = discovery.relabel.host.output
  job_name        = "node"
  scrape_interval = "30s"
  scrape_timeout  = "15s"
  forward_to      = [otelcol.receiver.prometheus.default.receiver]
}
ALLOYEOF
