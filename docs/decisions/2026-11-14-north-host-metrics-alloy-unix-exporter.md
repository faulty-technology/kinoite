---
type: Decision
date: 2026-11-14
subject: north host telemetry uses Alloy's built-in prometheus.exporter.unix with read-only /host/* mounts, instead of a separate node_exporter container
---

# north host metrics: Alloy's built-in unix exporter

## Decision

The north image's `alloy.container` quadlet gains three read-only host mounts —
`/proc:/host/proc`, `/sys:/host/sys`, `/:/host/root,rslave` — and a second config
file, `/etc/alloy/host.alloy`, running Alloy v1.21.3's built-in
`prometheus.exporter.unix` component (a node_exporter fork). It collects
`cpu`, `cpufreq`, `meminfo`, `loadavg`, `pressure`, `vmstat`, `diskstats`,
`netdev`, `filesystem`, `hwmon`, `thermal_zone`, `time`, `uname` plus the
textfile directory `/var/lib/alloy/textfile` (where `kinoite-gpu-metrics` writes
the R9700 gauges — see [2026-11-14-north-gpu-metrics](2026-11-14-north-gpu-metrics.md)).
A `prometheus.scrape` pulls the exporter every 30 s as `job="node"`, and a
`discovery.relabel` pins `instance="north"` (the exporter's default would be the
container's hostname).

## Why

- **Zero new daemons, zero new ports.** Alloy already runs on north as a system
  container with the OTLP pipeline to `nuc:31432`; the exporter is a component in
  that same process, scraped over loopback inside the host-network container.
- **One query set for both boxes.** Metric names are `node_*`, identical to the
  nuc's in-cluster node_exporter (kube-prometheus-stack), so a single dashboard
  template variable `$instance` serves both machines.
- The alternative — a second rootful node_exporter Quadlet with its own port and
  its own push/scrape plumbing — duplicates what this component already is.

## Trade-off accepted: host mounts into a privileged container

The quadlet is already `SecurityLabelDisable=true` and rootful (SELinux
confinement is off because a confined container cannot read `/var/log/journal`).
Binding the host rootfs read-only into it is a privilege increase over a journal
tailer: any code-execution bug in Alloy's exporter path could read the whole host
filesystem. Mitigations: all three mounts are `ro` (the rootfs one additionally
`rslave` to avoid propagating mounts back), the container runs on the host
network only inside the tailnet, and the image is pinned by digest. The fallback
— dropping `rootfs_path` and losing the `filesystem` collector's device
resolution — was considered and rejected: root-disk usage panels are worth more
than the marginal confinement.

## Rejected alternatives for the GPU gauges (the other half of host telemetry)

- **`amd-smi`** — no voltage-offset argument, and it core-dumps on gfx1201
  (documented in [overview](../overview.md)).
- **`rocm-smi`** — needs host ROCm; north has none by design (containers bundle
  ROCm 7).
- **`amdgpu_exporter` container** — a second daemon and a second port for ~10
  gauges, and it polls unconditionally, re-introducing the hwmon-wake problem the
  timer-based script solves with its `runtime_status` gate.
- **`lactd`** — installed but disabled; [gpu-power-and-fans](../explanation/gpu-power-and-fans.md)
  says to re-test on LACT bumps rather than assume it stays correct.
