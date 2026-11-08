#!/bin/bash
set -ouex pipefail

# radiance: Qwen3.8 on StillDeadcode's standalone radiance engine (C++/HIP, no vLLM). A
# hand-started LLM stack beside lemonade, vLLM and LLaMA-Factory, on :8005. Three units serve
# the same engine, port and model id with different models, and any one can be started:
#   radiance        27B MXFP4 with a merged DFlash2 drafter: AMD's post-training quant (Quark with
#                   AWQ), byte for byte, not a 4-bit-trained model.
#   radiance-fp8    27B FP8 with the same drafter.
#   radiance-flash  Flash Next, the 177B MoE: 4-bit experts, int8 trunk, MTP drafting.
# They conflict, so starting one stops the others. Why this engine replaced the patched-vLLM stack:
# docs/decisions/2026-10-18-radiance-engine-over-vllm-radiance.md. The three compared:
# docs/runs/2026-11-07-radiance-1170-code-fp8-vs-mxfp4.md, docs/runs/2026-11-08-radiance-1170-flash-next.md.
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
# Written after a full-file check, so later starts skip hashing 19–122 GB.
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

UNITS=(radiance radiance-fp8 radiance-flash)

# write_unit <unit> <model> <name> <rev> <sha256> <size> <shape>
# <shape> is the model's own serving flags; the rest of Exec= is shared.
write_unit() {
    local unit=$1 model=$2 name=$3 rev=$4 sha=$5 size=$6 shape=$7 others=() u
    for u in "${UNITS[@]}"; do [ "$u" = "$unit" ] || others+=("$u.service"); done
    cat > "/etc/containers/systemd/users/$unit.container" << QUADLETEOF
[Unit]
Description=radiance Qwen3.8 $model (radiance engine, dual R9700)
Documentation=https://codeberg.org/StillDeadcode/radiance
Documentation=file:///usr/share/kinoite/radiance.md

# Every unit wants both cards whole and the same port.
Conflicts=${others[*]}

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

# Host networking as upstream, bound to loopback only; 8000 is vllm.container's. The tailnet's
# HTTPS :8005 is tailscale serve's, on the tailnet address.
Network=host

Volume=%h/.local/share/models/radiance-engine:/models:ro

# The model's shape, then defaults shared by every unit. Sampling and reasoning defaults match the
# stack this replaced: a request that names its own wins. Same model id on every unit, so a client
# switches by starting another.
Exec=--model /models/$name.rad --served-model-name Qwen3.8 \\
    --host 127.0.0.1 --port 8005 \\
    $shape \\
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

# The 27B shape: both cards, the checkpoint's full window, 8 sequences, fp8 KV, an 8 GiB host tier
# for the prefix cache. --checkpoint-slots is left at auto, which sizes the snapshot store by
# --max-num-seqs. Evidence: docs/runs/2026-10-18-radiance-engine-181.md.
DENSE='--tp 2 --max-model-len 262144 --max-num-seqs 8 --kv-cache-dtype fp8 --prefix-cache-mib 8192'

# Flash Next's shape is the model card's command as measured: the routed experts do not fit both
# cards, so the hottest stay in VRAM and the rest stream from a 12 GiB pinned host pool, and the
# 47.7 GiB n-gram table is read from disk. 200K is the card's serving window. --tp-wire wht6 makes
# the cross-card all-reduce a lossy 6-bit payload. Evidence: docs/runs/2026-11-08-radiance-1170-flash-next.md.
FLASH='--tp 2 --tp-wire wht6 --max-model-len 200000 --max-num-seqs 8 --kv-cache-dtype fp8 --placement expert_tiered --host-pool-mib 12288 --gpu-headroom-mib 96 --num-speculative-tokens 3 --max-num-batched-tokens 2048 --ngram-placement disk'

write_unit radiance 27B-MXFP4 qwen3.8-27b-mxfp4 \
    60bd4139f335205fbc120e5534329c30b691af0e \
    a4908940c568f5f9dd24e88f46aefe9ac2ae07dfec023a2eaa1d14dcaa3df4f8 "19 GB" "$DENSE"
write_unit radiance-fp8 27B-FP8 qwen3.8-27b-fp8 \
    edd43fda378af6b3b5e8981b6e936145be9608fd \
    626ab844a8b45ddd5fcbb7b093700a73ed0fe0a7913a27e0eea6e72fb3f6cb1d "31 GB" "$DENSE"
write_unit radiance-flash Flash-Next qwen3.8-next-flash-fp8-iq4r-moe \
    8267a67384583f6be309981baf878b09ff900a9a \
    0af5e96244e80c21ac8edca1719dae49b8a201b94a2f3994c3e24026ceaa4d20 "122 GB" "$FLASH"

### 3. On-box runbook
# Source is docs/how-to/radiance.md.
install -D -m 0644 /ctx/docs/how-to/radiance.md /usr/share/kinoite/radiance.md

### 4. Gate the generated units
# Environment= under [Service] would set the variable on podman rather than in the container, and
# systemd accepts that silently.
files=()
for u in "${UNITS[@]}"; do files+=("/etc/containers/systemd/users/$u.container"); done
awk 'FNR==1{s=0} /^\[Service\]/{s=1} s && /^Environment=/{print FILENAME": Environment= under [Service] — belongs in [Container]"; bad=1} END{exit bad?1:0}' \
    "${files[@]}" \
    || { echo "radiance.sh: bad key placement in a radiance unit (see above)" >&2; exit 1; }
