---
type: Decision
date: 2026-11-14
subject: north pushes radiance metrics and its journal to the nuc's OTel collector from a Grafana Alloy agent, instead of the nuc scraping north
---

# north telemetry: Alloy pushes OTLP to the nuc

## Decision

The north image ships `alloy.container`, a rootful system Quadlet enabled at
boot. It runs Grafana Alloy v1.21.3, the same release as the nuc's DaemonSet.
Alloy:
- scrapes radiance's `/metrics` on `127.0.0.1:8005` every 15 s as `job="radiance"`,
  `instance="north"`;
- tails `/var/log/journal`, system and user units, without debug priority;
- pushes both over OTLP/HTTP to `http://nuc:31432`, the homelab OTel collector's
  tailnet NodePort.

The collector routes metrics to Prometheus remote-write and logs to Loki. In
Loki a north line's unit is `service_name` and the box is
`service_namespace="north"`. The Grafana dashboard is upstream radiance's
`deploy/grafana/radiance.json`, which homelab vendors.

## Why

radiance has no push of its own: no OTLP, tracing, remote-write or webhooks
(upstream `docs/GUIDE.md` §6). Its telemetry is Prometheus `/metrics`, the JSON
endpoints and plain-text logs. So the choice was who pulls `/metrics`.

- **Rejected: the nuc's Prometheus scrapes `https://north:8005/metrics` through
  `tailscale serve`.** That is metrics only, with no logs. It also makes the
  nuc depend on north's serve config, and north suspends and hand-starts its
  LLM units, so the scrape would fail most of the day.
- **Rejected: otelcol-contrib on north instead of Alloy.** Its `journald`
  receiver shells out to `journalctl`, which the image doesn't carry. Alloy
  reads the journal natively, and the nuc already runs it with this config
  language.
- **The risk, checked before committing:** going Prometheus → OTLP →
  remote-write could rename metrics. The upstream dashboard queries 44 exact
  names such as `radiance:engine_steps_total` and
  `vllm:time_to_first_token_seconds_bucket`. A local pipeline on the
  workstation on 2026-11-14 used the pinned images (Alloy v1.21.3, collector
  0.164.0, Prometheus remote-write receiver) against a stub `/metrics`. Colon
  names, `_total` and the histogram series arrived unchanged, with
  `instance="north"` and `job="radiance"` intact. The same day, a journal →
  Alloy → collector → Loki 3.7.9 run tagged 200 of 200 streams with their own
  unit in `service_name`. Both are unverified on north itself.

## Costs

- The OTLP ingest has no auth, so anything on the tailnet can write. That is
  the homelab collector's existing trade-off, and this adds nothing new.
- The collector stamps `k8s.cluster.name=nuc` and `telemetry.source=external-cli`
  on everything it ingests, north included.
- A desktop journal is noisy. If Loki's 14-day / 20 GiB budget gets tight, the
  next step is a unit allowlist.
