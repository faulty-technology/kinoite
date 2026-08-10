#!/bin/bash
set -ouex pipefail

# Lemonade Server (local LLM) as a rootless Quadlet. No host ROCm — lemonade's
# llama.cpp builds bundle their own ROCm 7 runtime.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by
# hand with `systemctl --user start lemonade`. Runbook and gotchas are in
# /usr/share/kinoite/lemonade.md, written below.
#
# TODO(hardware): none of this has run on the box yet. See notes/.

# crun specifically — GroupAdd=keep-groups is a crun-only feature.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "llm.sh: missing $bin" >&2; exit 1; }
done

### 1. Seeded lemonade defaults
# nightly, not stable: stable has no gfx1201 support and silently runs on CPU.
# rocm_args is the iGPU-segfault workaround slot, deliberately left empty.
mkdir -p /usr/share/kinoite
cat > /usr/share/kinoite/lemonade-defaults.json << 'EOF'
{
  "rocm_channel": "nightly",
  "llamacpp": {
    "backend": "rocm",
    "rocm_args": ""
  }
}
EOF

### 2. Rootless Quadlet unit
# users/ (not users/$UID/) — the UID isn't knowable at build time.
mkdir -p /usr/share/containers/systemd/users
cat > /usr/share/containers/systemd/users/lemonade.container << 'EOF'
[Unit]
Description=Lemonade Server (local LLM, containerized ROCm)
Documentation=https://lemonade-server.ai/docs/
Documentation=file:///usr/share/kinoite/lemonade.md

[Container]
Image=ghcr.io/lemonade-sdk/lemonade-server:latest
ContainerName=lemonade

# The image runs as UID 10001, which maps to a subuid by default — bind mounts would
# come back subuid-owned. keep-id makes it you, which also lets the volumes skip :U
# (a recursive chown on every start).
UserNS=keep-id:uid=10001,gid=10001

# Headless/SSH fallback for render/video membership; no active seat means no ACL.
# May be inert here (containers/podman#27876, #28364) — confirm or drop.
GroupAdd=keep-groups

# Directory: podman adds every node under it, iGPU included. See notes/.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# Unauthenticated API — the 127.0.0.1 prefix is what keeps it off the tailnet.
PublishPort=127.0.0.1:13305:13305

# %h is expanded by systemd, not Quadlet. :z not :Z — :Z would relabel the whole
# model cache on every start, since Quadlet builds a new container each time.
Volume=%h/.local/share/lemonade/huggingface:/opt/lemonade/.cache/huggingface:z
Volume=%h/.local/share/lemonade/llama:/opt/lemonade/llama:z
Volume=%h/.local/share/lemonade/config:/opt/lemonade/.cache/lemonade:z

# Mounting this from /usr/share directly fails: container_t can't read usr_t, and
# :z can't fix it because /usr is read-only. Hence the ExecStartPre copy below.
Environment=LEMONADE_DEFAULTS_PATH=/opt/lemonade/.cache/lemonade/defaults.json

[Service]
# First start pulls a multi-GB image against systemd's 90s default.
TimeoutStartSec=900

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/lemonade/huggingface %h/.local/share/lemonade/llama %h/.local/share/lemonade/config
ExecStartPre=/usr/bin/install -m 0644 /usr/share/kinoite/lemonade-defaults.json %h/.local/share/lemonade/config/defaults.json

# No [Install] — hand-started on purpose.
EOF

### 3. On-box notes
# The box won't have this repo checked out when something breaks.
cat > /usr/share/kinoite/lemonade.md << 'EOF'
# kinoite-north: Lemonade Server (rootless Quadlet)

Ships at /usr/share/containers/systemd/users/lemonade.container, NOT enabled.

    systemctl --user daemon-reload      # only after an image update
    systemctl --user start lemonade
    curl -s http://127.0.0.1:13305/live

Web UI and API on http://127.0.0.1:13305 — loopback only, unauthenticated.
`systemctl --user enable lemonade` is expected to fail: generator-produced units
have no [Install] to act on. That's the guardrail, not a bug.

## Storage

    ~/.local/share/lemonade/huggingface   models
    ~/.local/share/lemonade/llama         llama.cpp + ROCm binaries (downloaded)
    ~/.local/share/lemonade/config        config.json, defaults.json, recipes

Owned by you (UserNS=keep-id), so du/rm/backup tools work normally.

## gfx1201 (R9700) gotchas

1. The stable ROCm channel has no gfx1201 support and silently falls back to CPU
   (~7x slower, no error). The image seeds rocm_channel=nightly, but that only
   applies on the FIRST run — config.json wins after. To fix an existing install:

       podman exec lemonade lemonade config set rocm_channel=nightly
       podman exec lemonade lemonade config set llamacpp.backend=rocm
       podman exec lemonade lemonade backends install llamacpp:rocm
       systemctl --user restart lemonade

2. ROCm llama.cpp can segfault at model warmup when a gfx1201 dGPU and the gfx1036
   iGPU are both visible (lemonade-sdk/lemonade#1921, llamacpp-rocm#96). This box is
   that pair, and the unit passes all of /dev/dri.

       podman exec lemonade lemonade config set llamacpp.rocm_args="-mg 0 -sm none"
       systemctl --user restart lemonade

   Or hide the iGPU. This must SHADOW the unit, not drop in — AddDevice= repeats:

       mkdir -p ~/.config/containers/systemd
       cp /usr/share/containers/systemd/users/lemonade.container \
          ~/.config/containers/systemd/
       # replace AddDevice=/dev/dri with the R9700 render nodes only.
       # re-derive them, don't trust renderD numbering: ls -l /dev/dri/by-path/
       systemctl --user daemon-reload

## SELinux

/dev/dri works out of the box. /dev/kfd is allowed read/write but not `map`, which
ROCm needs. If the server starts but finds no GPU:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    sudo setsebool -P container_use_devices on    # system-wide, all containers

Not baked into the image — setsebool -P state lives in /var/lib/selinux.

## Surviving logout

    loginctl enable-linger $USER
EOF
