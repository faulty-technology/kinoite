#!/bin/bash
set -ouex pipefail

# R9V: Qwen3.8 Flash Next (177B MoE, IQ4_XS, MTP) on the patched vLLM from kyuz0's R9V
# toolbox. A fourth hand-started LLM stack beside lemonade, vLLM and LLaMA-Factory, on :8004.
# Measured speed, placement and memory: docs/runs/2026-09-13-r9v-flash-next.md.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "r9v.sh: missing $bin" >&2; exit 1; }
done

mkdir -p /usr/share/kinoite/r9v

### 1. The image recipe
# The published r9v-rocm-10.0 tag was built before upstream's AMD SMI fix (e8481d6) and fails
# upstream's own device probe, so the box adds that one layer itself. Pinned by digest, so a
# republish upstream changes nothing here until this file changes.
cat > /usr/share/kinoite/r9v/Containerfile << 'CONTAINERFILEEOF'
# Built on the box by r9v.container's ExecStartPre, not in CI. See r9v.sh.
FROM docker.io/kyuz0/amd-r9700-toolboxes:r9v-rocm-10.0@sha256:8c1a3d80420d59b65232c52b8defd5a511c08dfe2aa2eeb65e938ca7a2e5ac86
USER root
# Torch loads SDK core's libamd_smi while Python amdsmi opens devel's copy, and two instances make
# GPU discovery return zero. Point devel's names at core's library, as upstream e8481d6 does.
RUN for name in libamd_smi.so libamd_smi.so.27 libamd_smi.so.27.0.0; do \
      cmp /opt/r9v/lib/python3.12/site-packages/_rocm_sdk_devel/lib/"$name" \
          /opt/r9v/lib/python3.12/site-packages/_rocm_sdk_core/lib/libamd_smi.so.27 \
      && ln -sfn ../../_rocm_sdk_core/lib/libamd_smi.so.27 \
          /opt/r9v/lib/python3.12/site-packages/_rocm_sdk_devel/lib/"$name" \
      || exit 1; \
    done
CONTAINERFILEEOF

### 2. Model fetch
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-r9v-fetch << 'FETCHEOF'
#!/bin/bash
# Make sure the R9V model package and its extracted embedding table are on disk, fetching them if
# anything is missing. Runs on the host as an ExecStartPre of r9v.container. Checks the files
# upstream's toolboxes/r9v/run.sh refuses to start without. Fails closed: the server cannot run
# without them.
set -euo pipefail

model=${1:?usage: kinoite-r9v-fetch <model-dir> <ple-file>}
ple=${2:?usage: kinoite-r9v-fetch <model-dir> <ple-file>}
image=localhost/kinoite-r9v:latest

required=(
    "$model"/target/Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3}-of-00003.gguf
    "$model/metadata/config.json" "$model/mtp/config.json" "$model/mtp/model.safetensors"
    "$model/vision/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf"
    "$model/manifests/hot-manifest-q4-vision-128k-multiprompt-r1-lru16-neutral.json"
)
complete() {
    local f
    for f in "${required[@]}"; do
        [ -r "$f" ] || return 1
    done
    [ "$(stat -c %s "$ple" 2>/dev/null)" = 28800138240 ]
}

if complete; then
    echo "kinoite-r9v-fetch: model and embedding table present"
    exit 0
fi

echo "kinoite-r9v-fetch: model incomplete; fetching ~90 GiB and extracting the embedding table"
echo "kinoite-r9v-fetch: this accepts the Qwen Community License 1.0"
mkdir -p "$model" "${ple%/*}"
run() { podman run --rm --pull=never --user 0:0 --security-opt label=disable "$@"; }
# r9v-model writes the table as /ple/per_layer_token_embd.iq4_nl.bin, so <ple-file> keeps that name.
run -v "$model:/models" "$image" r9v-model download --accept-model-license
run -v "$model:/models:ro" -v "${ple%/*}:/ple" "$image" r9v-model prepare
run -v "$model:/models:ro" "$image" r9v-model verify
complete || { echo "kinoite-r9v-fetch: still incomplete after fetching" >&2; exit 1; }
FETCHEOF
bash -n /usr/libexec/kinoite-r9v-fetch

### 3. Rootless Quadlet unit
# /etc/containers/systemd/users, same as the other stacks: podman 5.8.4 scans nothing else for
# rootless units.
mkdir -p /etc/containers/systemd/users

cat > /etc/containers/systemd/users/r9v.container << 'QUADLETEOF'
[Unit]
Description=R9V Qwen3.8 Flash Next (patched vLLM, dual R9700)
Documentation=https://github.com/kyuz0/amd-r9700-ai-toolboxes/blob/main/docs/r9v-rocm-10.0.md
Documentation=file:///usr/share/kinoite/r9v.md

# Bounds a restart loop: a start that fails for a durable reason (fetch, build, load) would
# otherwise retry every RestartSec forever.
StartLimitIntervalSec=1h
StartLimitBurst=3

[Container]
Image=localhost/kinoite-r9v:latest
Pull=never
ContainerName=r9v

# Upstream toolboxes/r9v/run.sh's posture, key for key: root in the user namespace, the host
# user's groups, host IPC for the TP=2 workers, no seccomp or SELinux confinement.
AddDevice=/dev/kfd
AddDevice=/dev/dri
User=0
Group=0
GroupAdd=keep-groups
SecurityLabelDisable=true
SeccompProfile=unconfined
PodmanArgs=--ipc=host

# Loopback only, like lemonade's 13305 and vLLM's 8000; 8000 stays vllm.container's.
PublishPort=127.0.0.1:8004:8000

# Fetched by kinoite-r9v-fetch, read-only inside. The cache holds r9v-serve's HOME and its
# Triton and inductor caches.
Volume=%h/.local/share/models/r9v/Qwen3.8-Flash-Next-IQ4_XS:/models:ro
Volume=%h/.local/share/models/r9v/ple/per_layer_token_embd.iq4_nl.bin:/ple/per_layer_token_embd.iq4_nl.bin:ro
Volume=%h/.local/share/r9v/cache:/cache

# R9V_VISIBLE_DEVICES for the R9700 pair, written per start by the ExecStartPre below. Keep %t
# bare; lemonade.sh explains why ./%t breaks.
EnvironmentFile=%t/kinoite-r9v/gpus.env

# Upstream config.env.example's 128K profile. R9V_PLE_WORKER_TIMING=0 is the one change: at 1 the
# server logs a timing line per prefill chunk, which would fill the journal.
Environment=R9V_PLE_RESIDENCY_MODE=ssd
Environment=R9V_PLE_WORKER_TIMING=0
Environment=R9V_MAX_MODEL_LEN=131072
Environment=R9V_MAX_NUM_SEQS=1
Environment=R9V_MAX_NUM_BATCHED_TOKENS=1024
Environment=R9V_KV_CACHE_MEMORY_BYTES=2285670400
Environment=R9V_TIERED_EXPERT_CACHE_SLOTS=16
Environment=R9V_CPU_OFFLOAD_GB=112.5
Environment=R9V_CPU_OFFLOAD_GB_BY_DEVICE=112.5,112.5
Environment=R9V_MTP_SPEC_TOKENS=2

Exec=r9v-serve

[Service]
# always, as vllm.container: an engine death exits cleanly, so on-failure would not recover it.
Restart=always
RestartSec=10

# A cold first start fetches ~117 GiB, builds the image and compiles before it serves.
TimeoutStartSec=7200

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/r9v/Qwen3.8-Flash-Next-IQ4_XS %h/.local/share/models/r9v/ple %h/.local/share/r9v/cache %t/kinoite-r9v

# Build only when the image is missing, as llamafactory.container does. Updating is a deliberate
# `podman rmi` (see r9v.md), never a surprise on restart.
ExecStartPre=/bin/sh -c 'podman image exists localhost/kinoite-r9v:latest || podman build -t localhost/kinoite-r9v:latest -f /usr/share/kinoite/r9v/Containerfile /usr/share/kinoite/r9v'

ExecStartPre=/usr/libexec/kinoite-r9v-fetch %h/.local/share/models/r9v/Qwen3.8-Flash-Next-IQ4_XS %h/.local/share/models/r9v/ple/per_layer_token_embd.iq4_nl.bin

# lemonade's helper derives the R9700 GPU-agent indices from KFD topology; R9V takes the same list
# under its own name. Always leaves gpus.env behind, empty if need be (podman treats a missing
# --env-file as fatal), and empty means R9V's own default of 0,1.
ExecStartPre=/bin/sh -c '/usr/libexec/kinoite-lemonade-gpus %t/kinoite-r9v/rocr.env; sed "s/^ROCR_VISIBLE_DEVICES=/R9V_VISIBLE_DEVICES=/" %t/kinoite-r9v/rocr.env > %t/kinoite-r9v/gpus.env 2>/dev/null || : > %t/kinoite-r9v/gpus.env'

# No [Install] — hand-started on purpose.
QUADLETEOF

### 4. On-box runbook
# Source is docs/how-to/r9v.md.
install -D -m 0644 /ctx/docs/how-to/r9v.md /usr/share/kinoite/r9v.md

### 5. Gate the generated unit
# Same check as llamafactory.sh: Environment= under [Service] would set the variable on podman
# rather than in the container, and systemd accepts that silently.
awk '/^\[Service\]/{s=1} s && /^Environment=/{print FILENAME": Environment= under [Service] — belongs in [Container]"; bad=1} END{exit bad?1:0}' \
    /etc/containers/systemd/users/r9v.container \
    || { echo "r9v.sh: bad key placement in r9v.container (see above)" >&2; exit 1; }
