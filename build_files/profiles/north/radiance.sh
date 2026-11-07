#!/bin/bash
set -ouex pipefail

# radiance: Qwen3.8-27B with a merged DFlash2 drafter, on StillDeadcode's standalone radiance engine
# (C++/HIP, no vLLM). A hand-started LLM stack beside lemonade, vLLM, LLaMA-Factory and R9V, on
# :8005. Two units serve the same engine and flags with different trunks, and either can be
# started:
#   radiance      MXFP4: AMD's post-training quant (Quark with AWQ), byte for byte, not a
#                 4-bit-trained model.
#   radiance-fp8  FP8, for a quality A/B against MXFP4. Not measured here yet.
# They conflict, so starting one stops the other. Why this engine replaced the patched-vLLM stack:
# docs/decisions/2026-10-18-radiance-engine-over-vllm-radiance.md.
command -v podman >/dev/null || { echo "radiance.sh: missing podman" >&2; exit 1; }

IMAGE=docker.io/stilldeadcode/radiance@sha256:c2acbaa373c89272ec47a22befa1cf04d2ddf1de51c2baf534f5273e517f7100

### 1. Host-side prepare
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-radiance-prepare << 'PREPAREEOF'
#!/bin/bash
# ExecStartPre of the radiance units, on the host. Makes sure the pinned .rad container is on disk,
# downloading it when missing and checking its sha256 once. <name> is both the Hugging Face repo
# under StillDeadcode and the file's stem. Fails closed: the server cannot run without it.
set -euo pipefail

usage="usage: kinoite-radiance-prepare <models-dir> <name> <rev> <sha256>"
models=${1:?$usage}
name=${2:?$usage}
rev=${3:?$usage}
sha=${4:?$usage}
rad=$models/$name.rad
# Written after a full-file check, so later starts skip hashing 19–31 GB.
ok=$rad.sha256-ok

if [ -r "$rad" ] && [ "$(cat "$ok" 2>/dev/null)" = "$sha" ]; then
    echo "kinoite-radiance-prepare: $name present"
    exit 0
fi

mkdir -p "$models"
rm -f "$ok"
# A file already in place may be this revision without its marker; hash it before fetching.
if [ -r "$rad" ] && [ "$(sha256sum "$rad" | cut -c1-64)" = "$sha" ]; then
    echo "$sha" > "$ok"
    echo "kinoite-radiance-prepare: $name present, checked"
    exit 0
fi
# Fetched beside the old file, which stays in place until the new one checks out. The .part is
# per revision, so a resumed download never appends to another revision's bytes.
part=$rad.$rev.part
echo "kinoite-radiance-prepare: fetching $name"
curl -fLC - --retry 5 --retry-delay 10 -sS -o "$part" \
    "https://huggingface.co/StillDeadcode/$name/resolve/$rev/$name.rad"
echo "kinoite-radiance-prepare: checking sha256"
got=$(sha256sum "$part" | cut -c1-64)
if [ "$got" != "$sha" ]; then
    echo "kinoite-radiance-prepare: sha256 $got, expected $sha; removing the download" >&2
    rm -f "$part"
    exit 1
fi
mv -f "$part" "$rad"
echo "$sha" > "$ok"
PREPAREEOF
bash -n /usr/libexec/kinoite-radiance-prepare

### 2. Rootless Quadlet units
# /etc/containers/systemd/users, same as the other stacks: podman 5.8.4 scans nothing else for
# rootless units.
mkdir -p /etc/containers/systemd/users

# write_unit <unit> <other-unit> <label> <name> <rev> <sha256> <size>
write_unit() {
    local unit=$1 other=$2 label=$3 name=$4 rev=$5 sha=$6 size=$7
    cat > "/etc/containers/systemd/users/$unit.container" << QUADLETEOF
[Unit]
Description=radiance Qwen3.8-27B $label (radiance engine, dual R9700)
Documentation=https://codeberg.org/StillDeadcode/radiance
Documentation=file:///usr/share/kinoite/radiance.md

# Both units want both cards whole and the same port.
Conflicts=$other.service

# Bounds a restart loop: a start that fails for a durable reason (fetch, load) would otherwise
# retry every RestartSec forever.
StartLimitIntervalSec=1h
StartLimitBurst=3

[Container]
Image=$IMAGE
Pull=never
ContainerName=$unit

# Upstream's deploy/compose/common.yaml in podman terms: the GPU nodes, the host user's groups,
# no seccomp (io_uring and the ROCm runtime's NUMA calls) and no SELinux confinement, unlimited
# locked memory for the pinned host buffers, and an init for SIGTERM.
AddDevice=/dev/kfd
AddDevice=/dev/dri
GroupAdd=keep-groups
SecurityLabelDisable=true
SeccompProfile=unconfined
Ulimit=memlock=-1
RunInit=true

# Host networking as upstream, bound to loopback only; 8000 is vllm.container's and 8004 is
# r9v.container's. The tailnet's HTTPS :8005 is tailscale serve's, on the tailnet address.
Network=host

Volume=%h/.local/share/models/radiance-engine:/models:ro

# The measured shape: both cards, the checkpoint's full window, 8 sequences, fp8 KV, an 8 GiB host
# tier for the prefix cache. --checkpoint-slots is left at auto, which sizes the snapshot store by
# --max-num-seqs. Sampling and reasoning defaults match the stack this replaced: a request that
# names its own wins. Same model id on both units, so a client switches by starting the other.
# Evidence (MXFP4): docs/runs/2026-10-18-radiance-engine-181.md.
Exec=--model /models/$name.rad --served-model-name Qwen3.8 \\
    --host 127.0.0.1 --port 8005 \\
    --tp 2 --max-model-len 262144 --max-num-seqs 8 --kv-cache-dtype fp8 \\
    --prefix-cache-mib 8192 \\
    --temp 0.7 --top-p 0.95 --top-k 20 \\
    --reasoning-effort medium --reasoning-effort-map high=xhigh,max=xhigh,minimal=low

[Service]
# always, as vllm.container: an engine death exits cleanly, so on-failure would not recover it.
Restart=always
RestartSec=10

# A first start downloads the $size container before it serves.
TimeoutStartSec=7200

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/radiance-engine

# Pre-pulled with plain \`podman pull\`: the implicit pull inside \`podman run\` is capped at 5 min
# under systemd (see vllm.sh).
ExecStartPre=/bin/sh -c 'podman image exists $IMAGE || podman pull $IMAGE'

ExecStartPre=/usr/libexec/kinoite-radiance-prepare %h/.local/share/models/radiance-engine $name $rev $sha

# No [Install] — hand-started on purpose.
QUADLETEOF
}

write_unit radiance radiance-fp8 MXFP4 qwen3.8-27b-mxfp4 \
    60bd4139f335205fbc120e5534329c30b691af0e \
    a4908940c568f5f9dd24e88f46aefe9ac2ae07dfec023a2eaa1d14dcaa3df4f8 "19 GB"
write_unit radiance-fp8 radiance FP8 qwen3.8-27b-fp8 \
    edd43fda378af6b3b5e8981b6e936145be9608fd \
    626ab844a8b45ddd5fcbb7b093700a73ed0fe0a7913a27e0eea6e72fb3f6cb1d "31 GB"

### 3. On-box runbook
# Source is docs/how-to/radiance.md.
install -D -m 0644 /ctx/docs/how-to/radiance.md /usr/share/kinoite/radiance.md

### 4. Gate the generated units
# Same check as r9v.sh: Environment= under [Service] would set the variable on podman rather than in
# the container, and systemd accepts that silently.
awk 'FNR==1{s=0} /^\[Service\]/{s=1} s && /^Environment=/{print FILENAME": Environment= under [Service] — belongs in [Container]"; bad=1} END{exit bad?1:0}' \
    /etc/containers/systemd/users/radiance.container /etc/containers/systemd/users/radiance-fp8.container \
    || { echo "radiance.sh: bad key placement in a radiance unit (see above)" >&2; exit 1; }
