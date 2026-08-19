#!/bin/bash
set -ouex pipefail

# vLLM (kyuz0's gfx1201/R9700 ROCm image) + Open WebUI as a rootless Quadlet POD, so the
# two spin up/down together and talk over the pod's shared localhost. Second, independent
# local-LLM stack alongside lemonade (lemonade.sh) — vLLM does batched tensor-parallel serving;
# lemonade does llama.cpp GGUF. They SHARE the model store (see the HF cache volume below).
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by hand with
# `systemctl --user start north-llm-pod`. Runbook and gotchas live in /usr/share/kinoite/vllm.md.
#
# TODO(hardware): none of this has run on the box yet. See notes/kinoite-north-validation.md.

# The kyuz0 image is built specifically for gfx1201 (the R9700). Its `start-vllm` wizard is
# interactive (dialog), but scripts/start_vllm.py ultimately just does
# os.execvpe("vllm", cmd, env) — so the headless launcher below reproduces that exec.

### 1. Headless vLLM launcher
# Baked to /usr/share/kinoite/vllm/, copied into the container at start (ExecStartPre) because
# /usr is read-only + usr_t-labeled — container_t can't read it and :z can't relabel a ro mount
# (same gotcha lemonade.sh documents). Flags follow kyuz0's FP8-27B recipe
# (RedHatAI/Qwen3.6-27B-FP8) for the default Qwen/Qwen3.8-27B-FP8: FP8 (8-bit, not Q4), TP=2,
# graph-compiled (NO --enforce-eager), full-precision KV, language-model-only, coder tool parser.
# EXCEPT context: 3.8-27B is model_type qwen3_5 — a HYBRID (48/64 layers linear-attention, only
# 16 full-attention) with native 262144. So growing KV is ~0.0625 GB/1K (fp16, 1/4 of a classic
# 27B), and 128K KV is only ~8 GB on top of ~27 GB FP8 weights. We seed 131072 (128K); native max
# is 262144 (256K, ~16 GB KV — also fits the pair), no rope-scaling needed. Switching VLLM_MODEL
# to a different family means adjusting these — see kyuz0's benchmarks/models.py and vllm.md.
mkdir -p /usr/share/kinoite/vllm
cat > /usr/share/kinoite/vllm/vllm-serve.sh << 'EOF'
#!/bin/bash
# Headless vLLM launcher — reproduces the exec that kyuz0's interactive start_vllm.py wizard
# ends in, for the model in $VLLM_MODEL. Overridable knobs: VLLM_TP, VLLM_MAX_SEQS,
# VLLM_MAX_MODEL_LEN, VLLM_GPU_UTIL, VLLM_MAX_BATCHED_TOKENS, plus the three perf experiments
# NCCL_PROTO, VLLM_FUSE_NORM_QUANT and VLLM_SPECULATIVE (see the comments at each, and the
# "Decode performance" section of vllm.md). All are settable from a systemd drop-in, so an
# experiment does not need an image rebuild.
set -euo pipefail

# kyuz0's ROCm/vLLM env (VLLM_TARGET_DEVICE=rocm, VLLM_USE_TRITON_AWQ=1,
# FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE, NCCL_PROTO=Simple, ...). Ships in the image; source
# it if present, otherwise assume the Dockerfile already exported these. Verify the real path
# with: podman run --rm docker.io/kyuz0/vllm-therock-gfx1201:latest env | grep -iE 'VLLM|TRITON'
for f in /opt/scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && source "$f"
done

# NCCL_PROTO: deliberately NOT forced to Simple any more (measured 2026-08-19, see notes/).
# On gfx1201 every fast all-reduce backend is arch-gated to CDNA in this vLLM build
# (rocm.py use_custom_allreduce() and quick_all_reduce.py supported_archs are both
# ["gfx94","gfx95"]), so TP falls through to PYNCCL — confirmed in the startup log:
#   Using ['PYNCCL'] all-reduce backends ... out of potential backends:
#   ['NCCL_SYMM_MEM','QUICK_REDUCE','FLASHINFER','CUSTOM','SYMM_MEM','PYNCCL']
# That makes PYNCCL's protocol load-bearing, and `Simple` is the WRONG one here: TP decode at
# batch 1 does 2 all-reduces per layer x 64 layers = 128 per token, each only hidden_size x 2B
# = 10 KiB. Simple is the high-bandwidth/high-latency protocol; it disables LL/LL128, which
# exist for exactly these tiny messages. Leaving it unset lets RCCL's tuner pick per size.
# The image itself sets no NCCL_/RCCL_ vars (verified via podman image inspect), so this
# assignment was the only thing setting it. Overridable, so Simple can be restored from a
# systemd drop-in (Environment=NCCL_PROTO=Simple) without rebuilding the image — the old
# unconditional export could not be overridden that way, which is why it is a knob now.
if [ -n "${NCCL_PROTO:-}" ]; then export NCCL_PROTO; fi

# Persistent compile cache: pay torch.compile / inductor / triton ONCE, not on every start (a full
# recompile of this 27B hybrid+FP8 graph is the ~6-8 min silent stretch at startup). We override the
# image default VLLM_DISABLE_COMPILE_CACHE=1 — kyuz0 disables it to avoid reusing stale graphs across
# image upgrades, but all three caches are keyed by a hash of the vLLM/torch/triton version + model
# + config, so an image bump just misses and recompiles cleanly. Set AFTER the source loop so we win
# over the image ENV. Dirs live on the mounted cache volume (see vllm.container); rm it to force a
# clean rebuild. (aiter's JIT under ~/.aiter is left ephemeral — it's cheap and version-fragile.)
export VLLM_DISABLE_COMPILE_CACHE=0
export VLLM_CACHE_ROOT=/opt/vllm-cache/vllm
export TORCHINDUCTOR_CACHE_DIR=/opt/vllm-cache/inductor
export TRITON_CACHE_DIR=/opt/vllm-cache/triton
mkdir -p "$VLLM_CACHE_ROOT" "$TORCHINDUCTOR_CACHE_DIR" "$TRITON_CACHE_DIR"

# Pin to the R9700s (gfx1201) only — never the gfx1036 iGPU. Set HIP_VISIBLE_DEVICES and NOT
# CUDA_/ROCR_VISIBLE_DEVICES: per start_vllm.py's find_r9700(), those conflict with HIP and hang
# vLLM at distributed (RCCL) init.
if command -v rocm-smi >/dev/null 2>&1; then
    idx=$(rocm-smi --showproductname 2>/dev/null \
        | grep -iE 'gfx1201|R9700' \
        | grep -oE 'GPU\[[0-9]+\]' | grep -oE '[0-9]+' \
        | sort -un | paste -sd, -) || true
    [ -n "${idx:-}" ] && export HIP_VISIBLE_DEVICES="$idx"
fi
echo "[vllm-serve] HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-<unset>} model=${VLLM_MODEL:?set VLLM_MODEL}"

# fuse_norm_quant: kyuz0 disables this norm-quant graph fusion because it crashed on gfx1201.
# That finding predates this image's vLLM (0.22.1rc1.dev499), so it's worth re-testing — but the
# default stays FALSE (safe) so a restart can't be broken by an untested flag. To test:
#   VLLM_FUSE_NORM_QUANT=true systemctl --user restart vllm     (via a drop-in Environment=)
# If it starts and generates sane text, flip the default here. If it crashes, that's your answer.
FUSE_NORM_QUANT="${VLLM_FUSE_NORM_QUANT:-false}"
case "$FUSE_NORM_QUANT" in
    true|false) ;;
    *) echo "[vllm-serve] VLLM_FUSE_NORM_QUANT must be true|false, got '$FUSE_NORM_QUANT'" >&2; exit 1 ;;
esac

# --compilation-config carries the fusion toggle above; the two TRITON_ATTN backends keep both the
# LM and the (unused, language-model-only) ViT numerically healthy on RDNA4. Otherwise lifted
# verbatim from start_vllm.py's launch path.
#
# --max-num-seqs default is 4, NOT kyuz0's 1. Measured 2026-08-19: the engine reports 426,942 KV
# tokens available (13.33 GiB/rank), which is 3.25x the 131072 context — so ~3 full-context or many
# short sequences fit with VRAM to spare, and at 1 the log shows real requests queueing
# ("Waiting: 1 reqs, Deferred: 1 reqs"). Batch-1 decode here is bound by a FIXED per-token cost
# (weights + 128 all-reduces), not by context, so batching amortises both and buys aggregate
# throughput for parallel agent tool calls at ~no single-stream cost. Set VLLM_MAX_SEQS=1 to get
# kyuz0's single-stream benchmarking behaviour back.
# NEXT EXPERIMENT — MTP speculative decoding, OFF by default (untested on this box). A knob
# rather than a commented-out flag on purpose: editing this script means rebuilding the image, so
# shipping it as an env var lets the experiment run from a systemd drop-in instead. To try it:
#   Environment='VLLM_SPECULATIVE={"method":"mtp","num_speculative_tokens":1}'
#
# This is the ONE lever that beats the memory-bandwidth roofline, because it emits several tokens
# per weight read AND amortises the 128 per-token all-reduces over them — it attacks both halves
# of the measured 42.6 ms/token budget. Verified available for THIS checkpoint (not inferred from
# a sibling model), 2026-08-19:
#   - config.json text_config.mtp_num_hidden_layers = 1  -> num_speculative_tokens 1
#   - the FP8 checkpoint really ships the weights: 22 mtp.* tensors in the safetensors index with
#     FP8 weight_scale_inv (mtp.fc.weight is unquantised BF16, matching the workaround noted at
#     vllm/model_executor/models/qwen3_5_mtp.py:81)
#   - vllm/config/speculative.py:460 maps model_type "qwen3_5" -> "qwen3_5_mtp", which is in
#     MTPModelTypes; registry.py:637 registers Qwen3_5MTP (dense; MoeMTP is the MoE sibling)
# Costs ~1 extra layer of VRAM; check the acceptance rate in the log before keeping it. Caveat:
# qwen3_5_mtp.py:373 says it does not support 'all' prefix caching (already off — hybrid arch).
EXTRA_ARGS=()
if [ -n "${VLLM_SPECULATIVE:-}" ]; then
    EXTRA_ARGS+=(--speculative-config "$VLLM_SPECULATIVE")
fi

# ${EXTRA_ARGS[@]+...} guard: expanding an empty array is an unbound-variable error under `set -u`
# on bash < 4.4, and this runs in whatever bash the upstream image ships.
exec vllm serve "$VLLM_MODEL" \
    --host 0.0.0.0 --port 8000 \
    --tensor-parallel-size "${VLLM_TP:-2}" \
    --max-num-seqs "${VLLM_MAX_SEQS:-4}" \
    --max-model-len "${VLLM_MAX_MODEL_LEN:-131072}" \
    --gpu-memory-utilization "${VLLM_GPU_UTIL:-0.95}" \
    --max-num-batched-tokens "${VLLM_MAX_BATCHED_TOKENS:-16384}" \
    --dtype auto \
    --trust-remote-code \
    --language-model-only \
    --attention-backend TRITON_ATTN \
    --compilation-config "{\"pass_config\":{\"fuse_norm_quant\":$FUSE_NORM_QUANT}}" \
    --mm-encoder-attn-backend TRITON_ATTN \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3 \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
EOF
chmod 0755 /usr/share/kinoite/vllm/vllm-serve.sh

# Fail the build loudly on a shell typo rather than shipping a launcher bash rejects.
bash -n /usr/share/kinoite/vllm/vllm-serve.sh

### 2. Rootless Quadlet: pod + two containers
# /etc, not /usr: podman 5.8.4 only scans /etc/containers/systemd/users{,/$UID} for rootless
# units. users/ (not users/$UID/) — the UID isn't knowable at build time. Same as lemonade.sh.
mkdir -p /etc/containers/systemd/users

# The pod owns the shared network namespace and the host port publishing. 127.0.0.1 prefix keeps
# both the (unauthenticated) UI and API off the tailnet — same posture as lemonade's 13305.
cat > /etc/containers/systemd/users/north-llm.pod << 'EOF'
[Unit]
Description=Local LLM stack (vLLM + Open WebUI)
Documentation=file:///usr/share/kinoite/vllm.md

[Pod]
PodName=north-llm
PublishPort=127.0.0.1:3000:8080
PublishPort=127.0.0.1:8000:8000
EOF

# vLLM: the GPU workload. Rootless podman maps container-root -> host-you, so the shared HF cache
# comes back owned by you with no keep-id (unlike lemonade's UID-10001 image).
cat > /etc/containers/systemd/users/vllm.container << 'EOF'
[Unit]
Description=vLLM OpenAI server (gfx1201 / dual R9700)
Documentation=https://github.com/kyuz0/amd-r9700-vllm-toolboxes
Documentation=file:///usr/share/kinoite/vllm.md

[Container]
Pod=north-llm.pod
Image=docker.io/kyuz0/vllm-therock-gfx1201:latest
ContainerName=vllm

# Directory: podman adds every node under it, iGPU included — the launcher excludes it via
# HIP_VISIBLE_DEVICES. See notes/.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# --ipc=host: multi-GPU RCCL shared memory (kyuz0's approach). It also drops the SELinux label
# separation that otherwise blocks `map` on /dev/kfd, so this works even without the
# container_use_devices boolean (which lemonade-selinux.service enables anyway). seccomp=unconfined
# + render/video groups per kyuz0's documented run flags.
PodmanArgs=--ipc=host --security-opt seccomp=unconfined --group-add video --group-add render

# Shared model store — the SAME HuggingFace hub cache lemonade mounts, so a model pulled by either
# runtime is visible to both. Download once, reuse everywhere. :z (shared label), not :Z.
Volume=%h/.local/share/models/huggingface:/root/.cache/huggingface:z
Environment=HF_HOME=/root/.cache/huggingface

# Copied-in launcher (see the /usr read-only note in the build script). :z so it's relabelable.
Volume=%h/.local/share/vllm/bin:/opt/kinoite:z

# Persistent torch.compile / inductor / triton cache — first start compiles (~6-8 min), every start
# after is fast. Version-hashed, so an image bump recompiles cleanly. rm this dir to force a rebuild.
Volume=%h/.local/share/vllm/cache:/opt/vllm-cache:z

# The one knob to change models. Launcher flags are tuned for this default (FP8 dense 27B).
Environment=VLLM_MODEL=Qwen/Qwen3.8-27B-FP8
Exec=/opt/kinoite/vllm-serve.sh

[Service]
# First start pre-pulls the ~32 GB image (ExecStartPre below) AND vLLM downloads the ~27 GB model;
# both must finish within this window, so give it an hour of headroom.
TimeoutStartSec=3600

# Pre-pull the image with a plain `podman pull` (bounded only by TimeoutStartSec), and ONLY when
# it's missing so routine restarts don't re-hit the network. This is load-bearing: the implicit
# pull inside `podman run` is HARD-CAPPED at 5 min under systemd and kills a slow first pull —
# confirmed on-box, first start died at exactly 5m03s on the 32 GB image. Updating the image is
# then a deliberate `podman pull` (see vllm.md), not a surprise re-download on every start.
ExecStartPre=/bin/sh -c 'podman image exists docker.io/kyuz0/vllm-therock-gfx1201:latest || podman pull docker.io/kyuz0/vllm-therock-gfx1201:latest'

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/huggingface %h/.local/share/vllm/bin %h/.local/share/vllm/cache
ExecStartPre=/usr/bin/install -m 0755 /usr/share/kinoite/vllm/vllm-serve.sh %h/.local/share/vllm/bin/vllm-serve.sh

# No [Install] — hand-started (the pod) on purpose.
EOF

# Open WebUI: the frontend. CPU-only (no devices); in-pod shared netns means it reaches vLLM on
# plain localhost. Ollama backend off; any key works since vLLM ignores it.
cat > /etc/containers/systemd/users/open-webui.container << 'EOF'
[Unit]
Description=Open WebUI (frontend for vLLM)
Documentation=https://docs.openwebui.com/
Documentation=file:///usr/share/kinoite/vllm.md

[Container]
Pod=north-llm.pod
Image=ghcr.io/open-webui/open-webui:main
ContainerName=open-webui
Volume=%h/.local/share/open-webui:/app/backend/data:z
Environment=OPENAI_API_BASE_URL=http://localhost:8000/v1
Environment=OPENAI_API_KEY=sk-noauth
Environment=ENABLE_OLLAMA_API=false

[Service]
Restart=always
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/open-webui
EOF

### 3. On-box notes
# The box won't have this repo checked out when something breaks.
cat > /usr/share/kinoite/vllm.md << 'EOF'
# kinoite-north: vLLM + Open WebUI (rootless Quadlet pod)

A second, independent local-LLM stack next to lemonade (see lemonade.md). vLLM does batched
tensor-parallel serving on both R9700s; Open WebUI is its frontend. They share one pod, so they
start and stop together. NOT enabled — hand-started:

    systemctl --user daemon-reload      # only after an image/unit update
    systemctl --user start north-llm-pod
    podman pod ps && podman ps

Endpoints, loopback only, unauthenticated:

    http://127.0.0.1:3000        Open WebUI
    http://127.0.0.1:8000/v1     vLLM OpenAI-compatible API (for coding agents)

If `start north-llm-pod` doesn't bring up both containers on this podman, start a member
instead — it pulls in the pod: `systemctl --user start vllm`.

First run is slow: the vLLM image is ~32 GB and the model ~27 GB, both downloaded once.
The unit pre-pulls the image itself (an ExecStartPre `podman pull`, since podman hard-caps the
implicit pull inside `podman run` at 5 min and kills a slow first pull). Watch progress with
`journalctl --user -u vllm -f`; the server is up when you see `Application startup complete` /
`Uvicorn running on http://0.0.0.0:8000`. To UPDATE the image later (the pre-pull only fires when
it's missing, so it won't happen on its own):

    podman pull docker.io/kyuz0/vllm-therock-gfx1201:latest
    systemctl --user restart vllm

Startup time: the FIRST start after a fresh image compiles the model graph (torch.compile +
inductor + triton) and takes ~6-8 min of mostly-silent work after "Starting to load model". That
compile is cached to `~/.local/share/vllm/cache`, so every start after is fast (~1-2 min). An image
update recompiles once (the cache is version-hashed — old entries just miss). To force a clean
rebuild, `rm -rf ~/.local/share/vllm/cache` and restart. Don't restart mid-compile — it throws the
progress away and starts over. To skip compilation entirely (eager, ~2 min start, ~10-20% slower
generation) add `--enforce-eager` to a shadowed launcher.

## Model store (shared with lemonade)

Everything downloads into ONE HuggingFace hub cache:

    ~/.local/share/models/huggingface/hub/

vLLM, lemonade, and any future experiment stack mount this same path, so a model is pulled once
and reused. Owned by you (rootless), so du/rm/backup work normally. New stacks: point at the same
directory.

## Switching models

The default is baked as `Environment=VLLM_MODEL=` in vllm.container. To change it, shadow the unit
(don't edit /etc — it's part of the image):

    mkdir -p ~/.config/containers/systemd/users
    cp /etc/containers/systemd/users/vllm.container ~/.config/containers/systemd/users/
    # edit VLLM_MODEL (and, if a different family, the tool/reasoning parser flags in the launcher
    # copy at ~/.local/share/vllm/bin/vllm-serve.sh)
    systemctl --user daemon-reload && systemctl --user restart vllm

Verified model IDs and their per-model configs (tp / ctx / util / parser flags) are in kyuz0's
benchmarks/models.py. The baked launcher's flags match the default FP8 dense 27B
(Qwen/Qwen3.8-27B-FP8, mirroring kyuz0's verified RedHatAI/Qwen3.6-27B-FP8): --language-model-only,
graph-compiled (no --enforce-eager), full-precision KV, qwen3_coder tool parser, qwen3 reasoning
parser. FP8 is 8-bit — NOT the 4-bit AWQ path. Other knobs are env-overridable: VLLM_TP,
VLLM_MAX_SEQS, VLLM_MAX_MODEL_LEN, VLLM_GPU_UTIL, VLLM_MAX_BATCHED_TOKENS, plus the perf knobs
NCCL_PROTO / VLLM_FUSE_NORM_QUANT / VLLM_SPECULATIVE (see "Decode performance" below).

## Decode performance

Measured 2026-08-19 on Qwen/Qwen3.8-27B-FP8, TP=2, batch 1: **23.5 tok/s**, and dead flat as
context grows (23.5 at 4.5% KV, 23.7 at 2.3%) — because 48 of the 64 layers are linear-attention
with constant-size state, so per-token cost is FIXED (weights + collectives), not context-driven.

Where the 42.6 ms/token goes:

    weight read   14.45 GiB shard / ~640 GB/s   ~24 ms   (~28-30 ms at a realistic 80-85% of spec)
    everything else                             ~12-18 ms

That remainder is tensor-parallel collectives. At batch 1 each layer does 2 all-reduces (mixer
out-proj, MLP down-proj) x 64 layers = **128 all-reduces per token**, each only hidden_size x 2B =
**10 KiB**. Both cards are PCIe 5.0 x16, where 10 KiB is sub-microsecond of wire time — so that
12-18 ms is essentially all per-op latency, not transfer.

The reason it is expensive: on gfx1201 every fast all-reduce backend is arch-gated to CDNA, so TP
falls through to the generic PYNCCL path. Confirmed in the startup log:

    Using ['PYNCCL'] all-reduce backends (in dispatch order) for group 'tp:0' out of potential
    backends: ['NCCL_SYMM_MEM','QUICK_REDUCE','FLASHINFER','CUSTOM','SYMM_MEM','PYNCCL']

Both gates are hard-coded to ["gfx94","gfx95"] in this image: `use_custom_allreduce()` in
vllm/platforms/rocm.py and `supported_archs` in
vllm/distributed/device_communicators/quick_all_reduce.py. No flag or env var changes that.

Knobs, in the order worth trying (all settable from a drop-in — no image rebuild):

    mkdir -p ~/.config/systemd/user/vllm.service.d
    cat > ~/.config/systemd/user/vllm.service.d/perf.conf << 'CONF'
    [Service]
    Environment='VLLM_SPECULATIVE={"method":"mtp","num_speculative_tokens":1}'
    CONF
    systemctl --user daemon-reload && systemctl --user restart vllm

1. `VLLM_SPECULATIVE` — MTP speculative decoding. The only lever that beats the bandwidth
   roofline: several tokens per weight read, and the 128 all-reduces amortised across them.
   This checkpoint really does ship the MTP weights (22 `mtp.*` tensors). Check the acceptance
   rate in the log before keeping it.
2. `NCCL_PROTO` — now UNSET by default (was forced to `Simple`, the high-latency protocol, which
   is wrong for 10 KiB messages). Set `NCCL_PROTO=Simple` to restore the old behaviour if RCCL
   misbehaves.
3. `VLLM_MAX_SEQS` — now 4 (was 1). Does not raise single-stream tok/s; it stops parallel agent
   requests queueing. There is room: the engine reports 426,942 KV tokens, 3.25x the 128K context.
4. `VLLM_FUSE_NORM_QUANT=true` — re-test the fusion kyuz0 disabled for a gfx1201 crash on an older
   vLLM. Default stays `false`. If it starts and generates sane text, flip the default in vllm.sh.

Not worth chasing: QuickReduce (arch-gated, never RDNA4); PP=2 instead of TP=2 (batch-1 decode
serialises both shards, ~21 tok/s, worse); TP=1 (29 GB of weights + KV will not fit 30.4 GB
usable); PCIe tuning (already 5.0 x16); the one-shot Triton JIT warnings (not steady state).
Higher ceiling but invasive: this image already patches `_ON_MI3XX` in rocm.py to include gfx1201,
so patching `use_custom_allreduce()` the same way may light up the one-shot custom all-reduce —
generic HIP, but needs correctness checking (garbage output / hangs), and pairs with `iommu=pt`
(`rpm-ostree kargs --append=iommu=pt`, reboot; no IOMMU kargs are set today).

Qwen3.8-27B is vision-capable; the launcher serves it text-only (--language-model-only) to save
VRAM. To enable vision, drop that flag in the launcher copy (costs VRAM).

Context: this is a HYBRID model (qwen3_5) — 48 of 64 layers are linear-attention (constant state),
only 16 are full-attention, so the growing KV cache is ~0.0625 GB/1K at fp16, a QUARTER of a
classic 27B. Native max is 262144 (256K). The default seeds 131072 (128K ≈ 8 GB KV, on top of
~27 GB FP8 weights). To go to the full 256K (~16 GB KV — still fits the 64 GB pair, no rope-scaling
needed), just set it:

    Environment=VLLM_MAX_MODEL_LEN=262144      # in the shadowed unit; 256K native

No fp8 KV-quant needed at these sizes; add `--kv-cache-dtype fp8` in the launcher only if you also
want vision or many concurrent sequences. (The model also ships MTP, mtp_num_hidden_layers=1 — a
potential vLLM `--speculative-config` speedup later, unverified on this ROCm build.)

## GPU selection

The launcher pins vLLM to the R9700s only, via HIP_VISIBLE_DEVICES (parsed from `rocm-smi
--showproductname`), and deliberately does NOT set CUDA_/ROCR_VISIBLE_DEVICES — those conflict with
HIP and hang vLLM at RCCL init. Check what it picked:

    podman logs vllm | grep -iE 'HIP_VISIBLE|R9700|does not support'

## SELinux / ipc

vLLM runs with --ipc=host (needed for multi-GPU RCCL shared memory), which also makes podman drop
SELinux label separation for the container — so the /dev/kfd `map` denial that bites lemonade
doesn't apply here. lemonade-selinux.service (container_use_devices) is enabled anyway as belt and
suspenders. If vLLM ever can't see the GPUs, check `sudo ausearch -m AVC -ts recent | grep
hsa_device_t`.

## Coding / agent use

Point your agent (opencode, aider, Continue, ...) at:

    base URL   http://127.0.0.1:8000/v1      (any api key; ignored)
    model      Qwen/Qwen3.8-27B-FP8   (or whatever VLLM_MODEL is set to)

The default has tool-calling (--enable-auto-tool-choice, qwen3_coder parser) enabled.

## Relationship to lemonade

Separate stack, separate ports (lemonade is :13305). They only share the model store above.
Run whichever you want; running both at once contends for VRAM, so stop one first.

## Surviving logout

    loginctl enable-linger $USER
EOF
