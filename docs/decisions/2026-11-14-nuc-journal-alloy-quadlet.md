---
type: Decision
date: 2026-11-14
subject: the nuc's host journal ships from an image-baked Alloy Quadlet shared with north, not from the privileged Flux DaemonSet
---

# nuc journal: image-baked Alloy, not a privileged pod

## Decision

The nuc image ships the same `alloy.container` Quadlet as north. Both now come
from `build_files/scripts/alloy.sh`, which writes `/etc/alloy/journal.alloy` per
box. It tails `/var/log/journal` and pushes OTLP/HTTP to the collector at
`http://127.0.0.1:31432`, the collector's NodePort on the nuc itself. north keeps
`http://nuc:31432` and adds `/etc/alloy/radiance.alloy`. Alloy loads the
directory, so the scrape feeds the shared batch processor.

In Loki a nuc journal line is `service_namespace="nuc"` with its unit as
`service_name`, the same scheme as north
([decisions/2026-11-14-north-telemetry-alloy-otlp.md]).

Once this is verified on the nuc, homelab's Alloy DaemonSet drops its
`loki.source.journal` block, the journal hostPath and `privileged: true`. It
keeps `loki.source.kubernetes` for pod logs, which reads through the API.

## Why

The DaemonSet runs privileged only to read the journal: the nuc is
SELinux-enforcing and a confined pod cannot read `/var/log/journal`. A host unit
with `SecurityLabelDisable=true` does the same read outside the cluster, so the
cluster loses its privileged log shipper. north already runs that unit.

- **Rejected: keep the journal in the DaemonSet.** It works, but it keeps a
  privileged pod on a tailnet-exposed node for one hostPath. It also leaves two
  journal pipelines with different label schemes (`host="nuc"`, `unit=` on the
  nuc versus `service_namespace`/`service_name` on north). Nothing in either repo
  queried the nuc's old labels.
- **Rejected: `loki.write` straight to Loki's NodePort.** That would keep the old
  labels, but it forks the config from north's. Going through the collector keeps
  one pipeline. The cost is the collector's `telemetry.source=external-cli` stamp,
  which north already carries.

## Costs

- The sink still runs in k3s. While k3s is down, lines wait behind the cursor in
  `/var/lib/alloy` and arrive late. Before this change they were not collected at
  all in that state.
- A change to the host pipeline now waits for an image build and the nuc's weekly
  apply window, where before it only needed a Flux push.
- Unverified: that the NodePort answers on the nuc's `127.0.0.1` (k3s's
  kube-proxy sets `route_localnet`). The fallback is `http://nuc:31432`.
- Verified on the workstation on 2026-11-14: `alloy validate` (v1.21.3, the
  pinned digest) passes on the generated configs for both boxes. It fails on
  `radiance.alloy` alone, which confirms the cross-file references resolve.
  Unverified on either box.
