#!/bin/bash
set -ouex pipefail

# alloy: a Grafana Alloy agent that tails the host journal, system and user units both, and
# pushes it over OTLP/HTTP to the nuc's OTel collector. The pipeline ends in
# otelcol.processor.batch.default, so a profile can drop more *.alloy files into /etc/alloy/
# that forward there (north's radiance scrape does). Why an image-baked agent rather than a
# cluster pod: docs/decisions/2026-11-14-north-telemetry-alloy-otlp.md and
# docs/decisions/2026-11-14-nuc-journal-alloy-quadlet.md.
#
#   ALLOY_HOST      box name; becomes the journal's host label, service.namespace and host.name
#   ALLOY_ENDPOINT  OTLP/HTTP base URL of the collector
#   ALLOY_AFTER     extra units the container starts after (space-separated, optional)

: "${ALLOY_HOST:?}" "${ALLOY_ENDPOINT:?}"
ALLOY_AFTER="${ALLOY_AFTER:-}"

# Same Alloy release as the nuc's DaemonSet (chart 1.15.0, appVersion v1.21.3).
IMAGE=docker.io/grafana/alloy:v1.21.3@sha256:8ab871206bd2d8f89277f53abffee5f452a293980788d52f85fa183a87a505a4

### 1. Pipeline
# Quoted heredoc: the OTTL statements carry backticks. @ALLOY_HOST@ and @ALLOY_ENDPOINT@ are
# substituted afterwards.
install -D -m 0644 /dev/stdin /etc/alloy/journal.alloy << 'ALLOYEOF'
// @ALLOY_HOST@ -> nuc OTel collector (OTLP/HTTP). Nothing here listens off-box.

// The journal: system units and the rootless user units. Debug priority is dropped; it is
// most of a desktop's volume.
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
  labels        = {job = "systemd", host = "@ALLOY_HOST@"}
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
      `set(resource.attributes["service.namespace"], "@ALLOY_HOST@")`,
      `set(resource.attributes["host.name"], "@ALLOY_HOST@")`,
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
  client { endpoint = "@ALLOY_ENDPOINT@" }
}
ALLOYEOF
sed -i -e "s|@ALLOY_HOST@|${ALLOY_HOST}|g" -e "s|@ALLOY_ENDPOINT@|${ALLOY_ENDPOINT}|g" \
    /etc/alloy/journal.alloy
! grep -q '@ALLOY_' /etc/alloy/journal.alloy

### 2. Unit
# Rootful system container on the host network: it reaches loopback services and the nuc by its
# MagicDNS name. SELinux confinement is off because a confined container cannot read
# /var/log/journal. Alloy loads every *.alloy file in /etc/alloy/. The UI binds loopback only.
# /var/lib/alloy holds the journal cursor, so a restart resumes where it stopped instead of
# re-sending.
# The /host/* mounts are a privilege increase over a journal tailer (host rootfs read-only
# into a SecurityLabelDisable=true rootful container); they exist for prometheus.exporter.unix
# (north's host.alloy). docs/decisions/2026-11-14-north-host-metrics-alloy-unix-exporter.md
install -D -m 0644 /dev/stdin /etc/containers/systemd/alloy.container << QUADLETEOF
[Unit]
Description=Grafana Alloy: ${ALLOY_HOST} telemetry to the nuc over OTLP
Documentation=https://grafana.com/docs/alloy/latest/
After=tailscaled.service${ALLOY_AFTER:+ $ALLOY_AFTER}

[Container]
Image=$IMAGE
ContainerName=alloy
Network=host
SecurityLabelDisable=true
Volume=/etc/alloy:/etc/alloy:ro
Volume=/var/log/journal:/var/log/journal:ro
Volume=/etc/machine-id:/etc/machine-id:ro
# Read-only host views for prometheus.exporter.unix; the exporter reads /host/{proc,sys,root}.
Volume=/proc:/host/proc:ro
Volume=/sys:/host/sys:ro
Volume=/:/host/root:ro,rslave
Volume=/var/lib/alloy:/var/lib/alloy
Exec=run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy /etc/alloy

[Service]
StateDirectory=alloy
Restart=always
RestartSec=10
# The first start pulls the image.
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
QUADLETEOF
