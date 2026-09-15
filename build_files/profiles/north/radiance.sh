#!/bin/bash
set -ouex pipefail

# radiance: Qwen3.8-27B in native MXFP4 with the DFlash2 FP8 drafter, on radiance-vllm-mxfp4's
# patched vLLM. A hand-started LLM stack beside lemonade, vLLM, LLaMA-Factory and R9V, on :8005.
# Measured speed, concurrency and memory: docs/runs/2026-09-15-radiance-mxfp4-dflash.md.
for bin in podman git; do
    command -v "$bin" >/dev/null || { echo "radiance.sh: missing $bin" >&2; exit 1; }
done

mkdir -p /usr/share/kinoite/radiance

### 1. In-container start
# The image cannot be a build base (buildah rejects its manifest, which mixes Docker and OCI layer
# media types), so the patches are applied at every start, as upstream's serve-mxfp4.sh does.
install -D -m 0755 /dev/stdin /usr/share/kinoite/radiance/radiance-start.sh << 'STARTEOF'
#!/bin/bash
# In-container start for radiance.container: patch this container's vLLM from the pinned checkout at
# /patches, compile radiance's W4A8 GEMM kernel, install the patched libr4d from /r4d, then hand off to
# the image's entrypoint with the unit's arguments. Steps and order are the container body of
# upstream's serve-mxfp4.sh at the pinned commit. Run under bash -l: hipcc comes from the image profile.
set -euo pipefail
SP=/opt/vllm/lib/python3.12/site-packages

# The image's own libr4d NaNs this model's gated-delta-net output, so a missing build is fatal.
[ -f /r4d/r4d.so ] || { echo "radiance-start: /r4d/r4d.so is missing" >&2; exit 1; }
mkdir -p /cache/vllm /cache/inductor /cache/triton /cache/aiter

cd /patches
for p in patch_quark_mxfp4 patch_nvfp4_mxfp4 patch_tp3_pad patch_ar_maxbytes patch_topk_triton_rows \
         patch_dflash_calib patch_dflash_mxfp4_kv patch_rmsquant_fusion patch_verify_head \
         patch_kv_group_size patch_topk_composite patch_gdn_shared_build patch_dflash_selector_topk \
         patch_gdn_merge_inproj patch_dynwidth patch_async_dynwidth patch_step_trace \
         patch_ar_geometry patch_ar_3rank patch_gdn_glue; do
    python3 "$p.py"
done
# Optional upstream too: without it, thinking-off requests come back with empty content.
python3 patch_qwen3_thinkoff.py \
    || echo "radiance-start: WARNING: thinkoff patch did not apply; thinking-off requests return empty content" >&2
cp mxfp4-configs/*.json "$SP"/aiter/ops/triton/configs/gemm/
cp radiance_preamble.py /opt/radiance_preamble.py
cp radiance_nvfp4.py radiance_mxfp4.py radiance_gdn.py radiance_rmsquant.py radiance_drafthead.py \
   radiance_verifyhead.py radiance_gdnmerge.py radiance_aroverlap.py radiance_topk.py \
   radiance_arnq.py radiance_tp3pad.py "$SP"/
hipcc -O3 -w -std=c++17 -fPIC -shared --offload-arch=gfx1201 $(python3 -m pybind11 --includes) \
    radiance_mxfp4_fp8.hip -o "$SP"/radiance_mxfp4_fp8.so
cp /r4d/r4d.so "$SP"/r4d.so
echo "[radiance] using patched r4d.so from /r4d"

# Out of /patches before exec, so nothing in the checkout precedes site-packages on sys.path.
cd /
exec /opt/radiance_entrypoint.sh "$@"
STARTEOF
bash -n /usr/share/kinoite/radiance/radiance-start.sh

### 2. Container environment
# serve-mxfp4.sh's container environment at the pinned commit with its defaults, as DRY_RUN=1 prints
# it on this box, minus the GPU indices (written per start) and R4D_SO (/r4d is mounted instead).
install -D -m 0644 /dev/stdin /usr/share/kinoite/radiance/radiance.env << 'ENVEOF'
HF_HUB_OFFLINE=1
VLLM_LOGGING_LEVEL=INFO
VLLM_NO_USAGE_STATS=1
VLLM_ROCM_USE_AITER=1
VLLM_ROCM_USE_AITER_UNIFIED_ATTENTION=1
VLLM_ROCM_USE_AITER_MHA=0
VLLM_ROCM_USE_AITER_MLA=0
VLLM_ROCM_USE_AITER_MOE=0
VLLM_ROCM_USE_AITER_LINEAR=0
VLLM_ROCM_USE_AITER_FP8BMM=0
VLLM_ROCM_USE_AITER_FP4BMM=0
VLLM_ROCM_USE_AITER_RMSNORM=0
NCCL_PROTO=Simple
RADIANCE_USE_R4D=1
RADIANCE_USE_R4D_AR=1
RADIANCE_USE_R4D_AR_QUANT=1
RADIANCE_R4D_REPORT=1
RADIANCE_AR_MAX_KB=86016
RADIANCE_PRESHUFFLE=1
RADIANCE_FUSE_RMS_QUANT=1
RADIANCE_MXFP4=1
RADIANCE_MXFP4_W4A8=1
RADIANCE_MXFP4_W4A8_MIN_M=0
RADIANCE_FAST_DRAFT=1
RADIANCE_DRAFT_TAU=0.20
RADIANCE_DRAFT_RERANK=80
RADIANCE_DFLASH_SELECTOR_TOPK=
RADIANCE_VERIFY_HEAD=1
RADIANCE_VERIFY_HEAD_MAX_M=32
RADIANCE_MXFP4_DEBUG=0
RADIANCE_MXFP4_PUREQUANT=0
RADIANCE_MXFP4_SYNC=0
RADIANCE_MXFP4_CLONE=0
RADIANCE_MXFP4_CHECKX=0
RADIANCE_MXFP4_PADOUT=0
RADIANCE_MXFP4_TN4_MIN_M=2048
RADIANCE_MXFP4_DECODE_MAX_M=64
RADIANCE_MXFP4_DECODE_NT=1
RADIANCE_MXFP4_A_TILED_MIN_M=513
RADIANCE_MXFP4_WPERM=1
RADIANCE_TP_PAD=0
RADIANCE_TP_PAD_INTERMEDIATE=
RADIANCE_TP_PAD_DRAFTER=1
RADIANCE_TP_PAD_STRICT=1
RADIANCE_GDN_MERGE_INPROJ=1
RADIANCE_GDN_NORM_QUANT=1
RADIANCE_GDN_STRIDED_GATES=0
RADIANCE_GDN_EMPTY_OUT=0
R4D_ATTN_FP8=3
RADIANCE_AR_OVERLAP=0
RADIANCE_GDN_FUSED_UPDATE=1
RADIANCE_DYNAMIC_WIDTH=1
RADIANCE_DYNW_ALPHA=0.35
RADIANCE_DYNW_MARGIN=2
RADIANCE_DYNW_MIN=2
RADIANCE_DYNW_MIN_BATCH=3
RADIANCE_AR_QNB=96
RADIANCE_AR_QNT=1024
MXFP4_CUMODE=0
RADIANCE_STEP_TRACE=0
RADIANCE_AR_OVERLAP_MIN_M=2048
RADIANCE_AR_OVERLAP_SLICES=4
RADIANCE_MXFP4_EPIFAST=1
RADIANCE_MXFP4_R4D_DECODE_MAX_M=0
RADIANCE_TOPK_TRITON_MIN_ROWS=1
RADIANCE_SKINNY_GEMM=1
RADIANCE_DFLASH_CALIB=
RADIANCE_DFLASH_CALIB_TOKENS=200000
RADIANCE_MXFP4_HOIST_QUANT=1
RADIANCE_MXFP4_TRACED_QUANT=1
RADIANCE_FP8_STREAM=1
RADIANCE_RMS_QUANT_FUSION=1
RADIANCE_MXFP4_SHADOW=
RADIANCE_MXFP4_SANITIZE=0
RADIANCE_NVFP4_MXFP4=0
RADIANCE_NVFP4_EXP=mse
RADIANCE_NVFP4_FP8_LAYERS=mxfp4
RADIANCE_NVFP4_BF16_LAYERS=in_proj_ba
RADIANCE_NVFP4_LMHEAD=bf16
RADIANCE_GDN_PATHS=both
RADIANCE_GDN_NANTRACE=0
RADIANCE_MXFP4_KERNEL_N=
RADIANCE_MXFP4_KERNEL_NK=
RADIANCE_MXFP4_CHECKALL=
RADIANCE_MXFP4_MHIST=0
RADIANCE_MXFP4_DECODE_KS=
RADIANCE_MXFP4_DECODE_BK=
RADIANCE_MXFP4_CHECK_MAX_M=128
RADIANCE_MXFP4_PERBLOCK_NK=
RADIANCE_MXFP4_REFLINEAR=0
VLLM_CACHE_ROOT=/cache/vllm
TORCHINDUCTOR_CACHE_DIR=/cache/inductor
TRITON_CACHE_DIR=/cache/triton
AITER_ROOT_DIR=/cache/aiter
TRITON_CACHE_AUTOTUNING=1
ENVEOF

### 3. Host-side prepare
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-radiance-prepare << 'PREPAREEOF'
#!/bin/bash
# ExecStartPre of radiance.container, on the host. Makes sure the pinned radiance-vllm-mxfp4 checkout,
# the rewritten MXFP4 checkpoint, the DFlash2 drafter and the patched libr4d are on disk, running the
# checkout's own setup-mxfp4.sh when any is missing, then writes this start's R9700 indices.
# Fails closed: the server cannot run without any of it.
set -euo pipefail

usage="usage: kinoite-radiance-prepare <state-dir> <models-dir> <gpus-env>"
state=${1:?$usage}
models=${2:?$usage}
gpus_env=${3:?$usage}

commit=9735329348ae1c9319f01cbe5f7004ec5f4dba63
image=docker.io/stilldeadcode/vllm-radiance@sha256:45694209177a55a1ab3ba6702fe6e978b1b66a6e66ae3fc066f8d579f7bc4c25
src=$state/src

complete() {
    [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" = "$commit" ] || return 1
    [ -r "$models/Qwen3.8-27B-MXFP4-mtpfp8/config.json" ] || return 1
    [ -r "$models/Qwen3.8-27B-MXFP4-mtpfp8/model.safetensors" ] || return 1
    [ -r "$models/Qwen3.8-27B-DFlash2-FP8/config.json" ] || return 1
    compgen -G "$models/Qwen3.8-27B-DFlash2-FP8/*.safetensors" >/dev/null || return 1
    # setup-mxfp4.sh builds libr4d under this key for the pinned commit's R4D_PIN and extras patch.
    [ -r "$state/libr4d/b9e42ab-rx6/r4d.so" ]
}

if complete; then
    echo "kinoite-radiance-prepare: checkout, checkpoints and libr4d present"
else
    echo "kinoite-radiance-prepare: incomplete; fetching ~21 GiB, rewriting the checkpoint (~15 min), building libr4d"
    if [ ! -d "$src/.git" ]; then
        rm -rf "$src"
        git clone -q https://codeberg.org/ggz14/radiance-vllm-mxfp4 "$src"
    fi
    git -C "$src" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$src" fetch -q origin
    git -C "$src" checkout -q "$commit"
    mkdir -p "$models" "$state/libr4d"
    # setup-mxfp4.sh mounts the models directory without :z; label it once so its containers can write.
    podman run --rm --pull=never -v "$models:/x:z" --entrypoint true "$image"
    MODELS=$models HF_CACHE=$HOME/.local/share/models/huggingface IMAGE=$image \
        R4D_CACHE=$state/libr4d RUNTIME=podman "$src/setup-mxfp4.sh" --yes
    complete || { echo "kinoite-radiance-prepare: still incomplete after setup-mxfp4.sh" >&2; exit 1; }
fi

# The checkout's gpu-detect.sh picks the cards from sysfs by VRAM, which leaves out the iGPU; upstream
# serves with its list as both ROCR_ and HIP_VISIBLE_DEVICES. It is not written for set -eu.
set +eu
# shellcheck source=/dev/null
. "$src/gpu-detect.sh"
set -eu
if [ "${RAD_TP:-0}" != 2 ] || [ -z "${RAD_GPU_INDICES:-}" ]; then
    echo "kinoite-radiance-prepare: expected two usable R9700s, found ${RAD_GPU_COUNT:-0}" >&2
    exit 1
fi
printf 'ROCR_VISIBLE_DEVICES=%s\nHIP_VISIBLE_DEVICES=%s\n' "$RAD_GPU_INDICES" "$RAD_GPU_INDICES" > "$gpus_env"
echo "kinoite-radiance-prepare: GPUs $RAD_GPU_INDICES"
PREPAREEOF
bash -n /usr/libexec/kinoite-radiance-prepare

### 4. Rootless Quadlet unit
# /etc/containers/systemd/users, same as the other stacks: podman 5.8.4 scans nothing else for
# rootless units.
mkdir -p /etc/containers/systemd/users

cat > /etc/containers/systemd/users/radiance.container << 'QUADLETEOF'
[Unit]
Description=radiance Qwen3.8-27B MXFP4 (patched vLLM, dual R9700)
Documentation=https://codeberg.org/ggz14/radiance-vllm-mxfp4
Documentation=file:///usr/share/kinoite/radiance.md

# Bounds a restart loop: a start that fails for a durable reason (fetch, patch, load) would
# otherwise retry every RestartSec forever.
StartLimitIntervalSec=1h
StartLimitBurst=3

[Container]
Image=docker.io/stilldeadcode/vllm-radiance@sha256:45694209177a55a1ab3ba6702fe6e978b1b66a6e66ae3fc066f8d579f7bc4c25
Pull=never
ContainerName=radiance

# In place of serve-mxfp4.sh's --privileged --network=host: the GPU nodes, the host user's groups,
# host IPC for the TP=2 workers, SYS_PTRACE, and no seccomp or SELinux confinement.
AddDevice=/dev/kfd
AddDevice=/dev/dri
GroupAdd=keep-groups
SecurityLabelDisable=true
SeccompProfile=unconfined
AddCapability=SYS_PTRACE
PodmanArgs=--ipc=host

# Loopback only; 8000 is vllm.container's and 8004 is r9v.container's.
PublishPort=127.0.0.1:8005:8005

# Checkout, checkpoints and libr4d come from kinoite-radiance-prepare and are read-only inside.
# The cache directory name is serve-mxfp4.sh's suffix for the graph-changing knobs in radiance.env.
Volume=%h/.local/share/radiance/src:/patches:ro
Volume=%h/.local/share/models/radiance:/models:ro
Volume=%h/.local/share/radiance/libr4d/b9e42ab-rx6:/r4d:ro
Volume=%h/.local/share/radiance/cache/w4a8-093-gdnm-nqft-fp8s-gnq:/cache
Volume=%h/.local/share/radiance/bin:/opt/kinoite:ro

EnvironmentFile=/usr/share/kinoite/radiance/radiance.env
# Written per start by kinoite-radiance-prepare. Keep %t bare; lemonade.sh explains why ./%t breaks.
EnvironmentFile=%t/kinoite-radiance/gpus.env

# serve-mxfp4.sh's vllm serve arguments at the pinned commit with its default batch shape, whose
# --kv-cache-memory is upstream's measured value for this hardware.
Entrypoint=/bin/bash
Exec=-l /opt/kinoite/radiance-start.sh /models/Qwen3.8-27B-MXFP4-mtpfp8 \
    --served-model-name Qwen3.8 Qwen3.6 Qwen3.8-MXFP4 --host 0.0.0.0 --port 8005 \
    --kv-cache-dtype fp8 --tensor-parallel-size 2 \
    --gpu-memory-utilization 0.98 --kv-cache-memory 18563072000 \
    --max-model-len 262144 --max-num-seqs 8 --max-num-batched-tokens 8192 \
    --attention-backend R4D \
    --speculative-config '{"method":"dflash","model":"/models/Qwen3.8-27B-DFlash2-FP8","num_speculative_tokens":7,"attention_backend":"TRITON_ATTN","disable_padded_drafter_batch":true,"draft_sample_method":"greedy"}' \
    --no-async-scheduling \
    --compilation-config '{"pass_config":{"fuse_norm_quant":true,"fuse_act_quant":true}}' \
    --enable-prefix-caching --mamba-cache-mode align \
    --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 \
    --override-generation-config '{"temperature":0.7,"top_p":0.95,"top_k":20}' \
    --chat-template /patches/qwen-fixed-v22.3.jinja

[Service]
# always, as vllm.container: an engine death exits cleanly, so on-failure would not recover it.
Restart=always
RestartSec=10

# A cold first start fetches ~21 GiB, rewrites the checkpoint and builds libr4d before it serves.
TimeoutStartSec=7200

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/radiance/cache/w4a8-093-gdnm-nqft-fp8s-gnq %h/.local/share/radiance/bin %t/kinoite-radiance

# Pre-pulled with plain `podman pull`: the implicit pull inside `podman run` is capped at 5 min
# under systemd (see vllm.sh).
ExecStartPre=/bin/sh -c 'podman image exists docker.io/stilldeadcode/vllm-radiance@sha256:45694209177a55a1ab3ba6702fe6e978b1b66a6e66ae3fc066f8d579f7bc4c25 || podman pull docker.io/stilldeadcode/vllm-radiance@sha256:45694209177a55a1ab3ba6702fe6e978b1b66a6e66ae3fc066f8d579f7bc4c25'

# Copied out of /usr, which the container cannot mount relabelled (see vllm.sh).
ExecStartPre=/usr/bin/install -m 0755 /usr/share/kinoite/radiance/radiance-start.sh %h/.local/share/radiance/bin/radiance-start.sh

ExecStartPre=/usr/libexec/kinoite-radiance-prepare %h/.local/share/radiance %h/.local/share/models/radiance %t/kinoite-radiance/gpus.env

# No [Install] — hand-started on purpose.
QUADLETEOF

### 5. On-box runbook
# Source is docs/how-to/radiance.md.
install -D -m 0644 /ctx/docs/how-to/radiance.md /usr/share/kinoite/radiance.md

### 6. Gate the generated unit
# Same check as r9v.sh: Environment= under [Service] would set the variable on podman rather than in
# the container, and systemd accepts that silently.
awk '/^\[Service\]/{s=1} s && /^Environment=/{print FILENAME": Environment= under [Service] — belongs in [Container]"; bad=1} END{exit bad?1:0}' \
    /etc/containers/systemd/users/radiance.container \
    || { echo "radiance.sh: bad key placement in radiance.container (see above)" >&2; exit 1; }
