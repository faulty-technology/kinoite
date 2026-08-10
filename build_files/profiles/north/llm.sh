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
# nightly channel is correctness, not preference: stable has no gfx1201 support and
# silently runs on CPU at ~1/7th speed. ctx_size because lemonade auto-tunes to 157140
# on a 27B — raise per-model if you have headroom. rocm_args is the one combination
# measured working (~35 tok/s vs ~29 on vulkan); whether --load-mode mmap is actually
# load-bearing was never isolated after the SELinux fix landed, so it stays.
mkdir -p /usr/share/kinoite
cat > /usr/share/kinoite/lemonade-defaults.json << 'EOF'
{
  "ctx_size": 32768,
  "rocm_channel": "nightly",
  "llamacpp": {
    "backend": "rocm",
    "rocm_args": "--load-mode mmap"
  }
}
EOF

### 2. SELinux: let containers mmap /dev/kfd
# container-selinux grants container domains hsa_device_t {open read write ioctl ...}
# but NOT map, and ROCm mmaps /dev/kfd. Without this every model load dies ~25ms in
# with an HSA abort — "Memory critical error by agent node-0 ... Reason: Memory in
# use.", exit 134 — which looks nothing like a permission problem and cost a long
# bisect to find. Confirmed by the only AVC in the whole trace:
#   denied { map } tclass=chr_file tcontext=...:hsa_device_t:s0
#
# Boolean state lives in /var/lib/selinux, so it can't ship in the image — same
# constraint as nix-selinux.service, and the same fix: a guarded oneshot. The check
# makes it a no-op after first boot.
#
# The alternative that also "worked" — SecurityLabelDisable=true or --ipc=host on the
# container (podman drops label separation when sharing host IPC) — buys the same thing
# by turning SELinux off for the container entirely. Not worth it for one permission.
# Narrower still would be a CIL module granting only map on hsa_device_t; worth doing
# if this boolean's breadth ever matters.
for bin in getsebool setsebool; do
    command -v "$bin" >/dev/null || { echo "llm.sh: missing $bin" >&2; exit 1; }
done

cat > /usr/lib/systemd/system/lemonade-selinux.service << 'EOF'
[Unit]
Description=SELinux boolean allowing containers to mmap GPU compute devices
Documentation=file:///usr/share/kinoite/lemonade.md
ConditionSecurity=selinux

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'getsebool container_use_devices | grep -q " on$" || setsebool -P container_use_devices on'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

### 3. Rootless Quadlet unit
# /etc, not /usr: podman 5.8.4 only searches /etc/containers/systemd/users{,/$UID}
# for rootless units — the /usr/share equivalent is documented but not scanned.
# users/ (not users/$UID/) — the UID isn't knowable at build time.
mkdir -p /etc/containers/systemd/users
cat > /etc/containers/systemd/users/lemonade.container << 'EOF'
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

### 4. On-box notes
# The box won't have this repo checked out when something breaks.
cat > /usr/share/kinoite/lemonade.md << 'EOF'
# kinoite-north: Lemonade Server (rootless Quadlet)

Ships at /etc/containers/systemd/users/lemonade.container, NOT enabled.

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

## If ROCm dies at model load

Symptom, ~25ms into load_model, before any tensor output:

    Memory critical error by agent node-0 ... Reason: Memory in use.
    llama-server process has terminated with exit code: 134

This is SELinux denying `map` on /dev/kfd, which ROCm mmaps. It looks nothing like a
permission error. Check and fix:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    systemctl status lemonade-selinux.service
    sudo setsebool -P container_use_devices on

lemonade-selinux.service does this at boot; if it's masked or failed, you get the abort.

Tested and does NOT help — don't re-chase: capping ctx_size, `-mg 0 -sm none`,
`--load-mode mmap` alone, `ROCR_VISIBLE_DEVICES`, seccomp=unconfined. `--ipc=host` and
`SecurityLabelDisable=true` DO work, but only because podman drops SELinux label
separation for the container — same fix, bigger hammer.

## Performance notes

Measured: 27B Q5_K_M (21.2 GB), layer split, ctx 32768 — ROCm ~35 tok/s, Vulkan ~29.
Fall back to vulkan any time with `lemonade config set llamacpp.backend=vulkan`.

Both are near the ~30 tok/s single-card bandwidth ceiling (~640 GB/s ÷ 21.2 GB), which
is why the backend gap is only ~20%. MTP speculation is what gets ROCm above the naive
ceiling. The lever with real headroom is a smaller model, not tuning.

`-sm row` (tensor split, would use both cards' bandwidth) is unavailable:
`device ROCm0 does not support split buffers` — needs peer-copy compiled into the
llamacpp-rocm build. Layer split is the ceiling; the second card adds capacity, not
bandwidth. Recheck on llamacpp-rocm bumps.

All three GPUs are visible to the container, so layer split may put layers on the
gfx1036 iGPU, which would bottleneck every one of them. Check:

    podman logs lemonade | grep -iE 'buffer size|assigned|ROCm[0-9]'

If it is, pin to the R9700s. Re-derive the indices rather than trusting these —
`grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties`, where
120001 is an R9700 and 100306 the iGPU:

    llamacpp.rocm_args="--load-mode mmap -ts 1,1,0"     # zero weight to device 2
    # or, on the container: Environment=ROCR_VISIBLE_DEVICES=...

Not baked, because these indices move with kernel and slot changes.

## Other gotchas

The stable ROCm channel has no gfx1201 support and silently falls back to CPU (~7x
slower, no error). The image pins rocm_channel=nightly, but seeds only apply on the
FIRST run; config.json wins after:

    podman exec lemonade lemonade config set rocm_channel=nightly
    podman exec lemonade lemonade backends install llamacpp:rocm

To change device passthrough you must SHADOW the unit, not drop in, since AddDevice=
is a repeated key:

    mkdir -p ~/.config/containers/systemd
    cp /etc/containers/systemd/users/lemonade.container ~/.config/containers/systemd/
    systemctl --user daemon-reload

Note this cannot hide a GPU from ROCm — ROCr enumerates agents from the KFD topology
(/sys/class/kfd/kfd/topology/nodes/), which is global. Use ROCR_VISIBLE_DEVICES.

## SELinux

/dev/dri works out of the box. /dev/kfd is allowed read/write but not `map`, which
ROCm needs. If the server starts but finds no GPU:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    sudo setsebool -P container_use_devices on    # system-wide, all containers

Not baked into the image — setsebool -P state lives in /var/lib/selinux.

## Surviving logout

    loginctl enable-linger $USER
EOF
