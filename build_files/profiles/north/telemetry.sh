#!/bin/bash
set -ouex pipefail

# telemetry: a Grafana Alloy agent that pushes north's metrics and logs to the nuc's OTel
# collector over OTLP/HTTP. It scrapes radiance's Prometheus /metrics on loopback and tails the
# journal, system and user units both. Why push from an agent rather than have the nuc scrape:
# docs/decisions/2026-11-14-north-telemetry-alloy-otlp.md.

# Same Alloy release as the nuc's DaemonSet (chart 1.15.0, appVersion v1.21.3).
IMAGE=docker.io/grafana/alloy:v1.21.3@sha256:8ab871206bd2d8f89277f53abffee5f452a293980788d52f85fa183a87a505a4

### 1. Pipeline
install -D -m 0644 /dev/stdin /etc/alloy/config.alloy << 'ALLOYEOF'
// north -> nuc OTel collector (NodePort 31432, OTLP/HTTP). Nothing here listens off-box.

// radiance's /metrics, on loopback. All three radiance units share the port, so one target
// covers whichever is running; up == 0 while none is.
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

// The journal: system units and the rootless user units (radiance, vllm, lemonade, ...).
// Debug priority is dropped; it is most of a desktop's volume.
loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal_priority"]
    regex         = "7"
    action        = "drop"
  }

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }

  rule {
    source_labels = ["__journal__systemd_user_unit"]
    target_label  = "user_unit"
  }

  rule {
    source_labels = ["__journal_syslog_identifier"]
    target_label  = "ident"
  }
}

loki.source.journal "host" {
  path          = "/var/log/journal"
  labels        = {job = "systemd", host = "north"}
  relabel_rules = loki.relabel.journal.rules
  forward_to    = [otelcol.receiver.loki.default.receiver]
}

otelcol.receiver.loki "default" {
  output { logs = [otelcol.processor.transform.journal.input] }
}

// Loki indexes only a few OTLP resource attributes; service.name and service.namespace are two
// of them. So a line's unit becomes service.name (user unit first, since every user unit also
// carries user@UID.service as its system unit), and service.namespace marks the box.
otelcol.processor.transform "journal" {
  error_mode = "ignore"

  log_statements {
    context    = "log"
    statements = [
      `set(resource.attributes["service.name"], attributes["user_unit"]) where attributes["user_unit"] != nil`,
      `set(resource.attributes["service.name"], attributes["unit"]) where resource.attributes["service.name"] == nil and attributes["unit"] != nil`,
      `set(resource.attributes["service.name"], attributes["ident"]) where resource.attributes["service.name"] == nil and attributes["ident"] != nil`,
      `set(resource.attributes["service.namespace"], "north")`,
      `set(resource.attributes["host.name"], "north")`,
    ]
  }

  output { logs = [otelcol.processor.batch.default.input] }
}

otelcol.processor.batch "default" {
  output {
    metrics = [otelcol.exporter.otlphttp.nuc.input]
    logs    = [otelcol.exporter.otlphttp.nuc.input]
  }
}

// http/protobuf, not gRPC: the tailnet's 1280-byte MTU.
otelcol.exporter.otlphttp "nuc" {
  client { endpoint = "http://nuc:31432" }
}
ALLOYEOF

### 2. Unit
# Rootful system container on the host network: it reaches radiance on 127.0.0.1 and the nuc by
# its MagicDNS name. SELinux confinement is off because a confined container cannot read
# /var/log/journal. The UI binds loopback only. /var/lib/alloy holds the journal cursor, so a
# restart resumes where it stopped instead of re-sending.
install -D -m 0644 /dev/stdin /etc/containers/systemd/alloy.container << QUADLETEOF
[Unit]
Description=Grafana Alloy: north metrics and journal to the nuc over OTLP
Documentation=https://grafana.com/docs/alloy/latest/
Documentation=file:///usr/share/kinoite/radiance.md
After=tailscaled.service

[Container]
Image=$IMAGE
ContainerName=alloy
Network=host
SecurityLabelDisable=true
Volume=/etc/alloy/config.alloy:/etc/alloy/config.alloy:ro
Volume=/var/log/journal:/var/log/journal:ro
Volume=/etc/machine-id:/etc/machine-id:ro
Volume=/var/lib/alloy:/var/lib/alloy
Exec=run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy /etc/alloy/config.alloy

[Service]
StateDirectory=alloy
Restart=always
RestartSec=10
# The first start pulls the image.
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
QUADLETEOF
