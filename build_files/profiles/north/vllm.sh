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
# "Decode performance" section of vllm.md).
#
# HOW TO OVERRIDE THESE — this is a QUADLET container, and the obvious way does not work.
# A systemd drop-in (~/.config/systemd/user/vllm.service.d/*.conf) with [Service] Environment=
# sets the variable on the PODMAN process on the host; podman only forwards what the .container
# file declares, so it never reaches the container and the knob silently has no effect. Verified
# the hard way on 2026-08-19: systemd showed VLLM_GPU_UTIL=0.90 in the unit while the container
# still ran --gpu-memory-utilization 0.95. Override with [Container] Environment= in a shadowed
# unit instead (same method the "Switching models" section of vllm.md uses for VLLM_MODEL):
#     mkdir -p ~/.config/containers/systemd/users
#     cp /etc/containers/systemd/users/vllm.container ~/.config/containers/systemd/users/
#     # add e.g.  Environment=VLLM_GPU_UTIL=0.90   under [Container]
#     systemctl --user daemon-reload && systemctl --user restart vllm
# Note a shadowed unit is a full copy, so it will not pick up changes made to the baked unit by
# a later image build — re-copy it after one.
set -euo pipefail

# Remember what the CALLER asked for before the source loop below can clobber it. Load-bearing:
# the image's /etc/profile.d/01-rocm-envs.sh exports NCCL_PROTO=Simple, so anything we decide
# about NCCL_PROTO has to be (re)applied AFTER sourcing, exactly like VLLM_DISABLE_COMPILE_CACHE
# further down. Set NCCL_PROTO= (explicitly empty) to unset it and let RCCL's tuner choose.
NCCL_PROTO_WANT="${NCCL_PROTO-Simple}"

# kyuz0's ROCm/vLLM env. On this image (verified on box 2026-08-19) the SECOND path exists and is
# sourced — it is NOT a no-op, contrary to an earlier note. It exports 7 vars:
#   TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1  FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
#   VLLM_TARGET_DEVICE=rocm  VLLM_USE_TRITON_AWQ=1  VLLM_DISABLE_COMPILE_CACHE=1
#   NCCL_PROTO=Simple  PYTHONNOUSERSITE=1
# The last two are the ones we deliberately override below/after. Re-check after an image bump:
#   podman run --rm docker.io/kyuz0/vllm-therock-gfx1201:latest \
#       sh -c 'cat /etc/profile.d/01-rocm-envs.sh'
for f in /opt/scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && source "$f"
done

# NCCL_PROTO: kept at the image's Simple, but now as an overridable knob rather than an
# unconditional export (the old form could not be overridden at all).
#
# On gfx1201 every fast all-reduce backend is arch-gated to CDNA in this vLLM build
# (rocm.py use_custom_allreduce() and quick_all_reduce.py supported_archs are both
# ["gfx94","gfx95"]), so TP falls through to PYNCCL — confirmed in the startup log:
#   Using ['PYNCCL'] all-reduce backends ... out of potential backends:
#   ['NCCL_SYMM_MEM','QUICK_REDUCE','FLASHINFER','CUSTOM','SYMM_MEM','PYNCCL']
# That makes PYNCCL's protocol load-bearing. Theory said Simple was wrong here (it disables the
# LL/LL128 low-latency protocols, and TP decode at batch 1 does 2 all-reduces per layer x 64
# layers = 128 per token of only hidden_size x 2B = 10 KiB each). MEASUREMENT SAID OTHERWISE —
# a 2-rank RCCL all-reduce benchmark on this box, 2026-08-19:
#     10 KiB   Simple 27.6 us/op   auto 35.0 us/op    -> Simple wins
#     40 KiB   Simple 26.9         auto 32.7
#      1 MiB   Simple 82.2         auto 82.3          -> equal once bandwidth-bound
# So Simple is ~7 us/op faster at the size that matters, ~1 ms/token over 128 all-reduces.
# Do not "fix" this back to unset without re-measuring. The same benchmark also sized comm at
# only ~4.5 ms of the ~41 ms token budget, i.e. ~11% — collectives are NOT the bottleneck.
# To let RCCL's tuner choose instead, set NCCL_PROTO to the empty string in the shadowed
# .container (see the note on [Container] Environment= below).
if [ -n "$NCCL_PROTO_WANT" ]; then
    export NCCL_PROTO="$NCCL_PROTO_WANT"
else
    unset NCCL_PROTO
fi
unset NCCL_PROTO_WANT

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
#   add  Environment=VLLM_FUSE_NORM_QUANT=true  to a shadowed .container (see the header note)
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
# MTP speculative decoding — ON by default. This is the single biggest win found on this box:
# it emits ~1.9 tokens per forward pass, so the ENTIRE per-token cost is amortised across them,
# whatever that cost is made of. Measured on-box 2026-08-19 (slope method, batch 1, this image):
#     workload      off      on
#     rust code    24.3 -> 41.74 tok/s   (+72%)
#     python code  24.3 -> 40.43         (+66%)
#     prose        24.3 -> 38.72         (+59%)
# Acceptance length 1.91, acceptance rate 86-100%. For scale: tuned llama.cpp on the same pair of
# R9700s does 31.24 tok/s on this model, so MTP puts vLLM ~33% past it.
#
# Verified available for THIS checkpoint (not inferred from a sibling model):
#   - config.json text_config.mtp_num_hidden_layers = 1  -> num_speculative_tokens 1
#   - the FP8 checkpoint really ships the weights: 22 mtp.* tensors in the safetensors index with
#     FP8 weight_scale_inv (mtp.fc.weight is unquantised BF16, matching the workaround noted at
#     vllm/model_executor/models/qwen3_5_mtp.py:81)
#   - vllm/config/speculative.py:460 maps model_type "qwen3_5" -> "qwen3_5_mtp", which is in
#     MTPModelTypes; registry.py:637 registers Qwen3_5MTP (dense; MoeMTP is the MoE sibling)
#
# Correctness: greedy output does NOT match non-speculative byte-for-byte, and that is EXPECTED,
# not a bug. A control on this box proved batch shape alone flips the same tokens with no
# speculation involved: the same prompt, greedy, run alone vs. batched with 3 others diverged at
# the identical character offset with the identical alternatives. FP8 logits produce near-ties and
# the argmax follows whatever reduction order the batch shape implies. Spot checks all pass
# (counting 1-40 exact, 17*23=391). Do not re-run a bit-identity test as a correctness gate — the
# non-speculative baseline is not shape-stable either, so the test cannot pass.
#
# Costs ~1 extra layer of VRAM. Caveat: qwen3_5_mtp.py:373 says it does not support 'all' prefix
# caching (already off — the hybrid arch disables it). Set VLLM_SPECULATIVE= (explicitly empty)
# to turn speculation off. Do NOT chase a newer image for this: vLLM 0.27.1 was tested and is
# WORSE here (MTP 34.66 vs 40.75 on the identical prompt), with an unchanged 24.34 baseline.
EXTRA_ARGS=()
SPEC_DEFAULT='{"method":"mtp","num_speculative_tokens":1}'
SPEC="${VLLM_SPECULATIVE-$SPEC_DEFAULT}"
if [ -n "$SPEC" ]; then
    EXTRA_ARGS+=(--speculative-config "$SPEC")
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

All measured on-box 2026-08-19, Qwen/Qwen3.8-27B-FP8, TP=2, batch 1.

    with MTP (the default)   38.7 - 41.7 tok/s  depending on workload
    without MTP              24.3 tok/s

24.3 is dead flat in context — 24.35 at a 15-token prompt down to 22.99 at 32K, a 4% decline over
a 2000x context increase — because 48 of the 64 layers are linear-attention with constant-size
state, so per-token cost is FIXED, not context-driven. Confirmed independently by vLLM's own
`Avg generation throughput` logger across twelve service starts, which never exceeded 24.3.

Where the non-speculative 41 ms/token goes (each line measured, not inferred):

    FP8 GEMVs       21.5 ms   12.16 GB/rank/token at 565 GB/s effective
    all-reduce       4.5 ms   128 ops/token x 10 KiB, 35 us/op measured
    unexplained     ~15 ms
    ------------------------
    total           41.0 ms

The hardware is healthy and is NOT the limit: a synthetic large read measures **587.9 GB/s**, 92%
of the 640 GB/s spec, and the FP8 GEMVs hit 96% of that. An external datapoint corroborates the
ceiling to within 2% — llama.cpp on a single R9700 streams this model at an implied 577 GB/s.

MTP matters precisely because it does not require explaining that ~15 ms: emitting ~1.9 tokens per
forward pass amortises the whole budget regardless of what it is made of.

DEAD ENDS — all eliminated by measurement on this box, do not re-chase without new evidence:
NCCL_PROTO / all-reduce protocol (comm is only 11% of the budget); context length (flat, above);
cudagraph capture (CUDAGraphMode.NONE changed nothing); FP8 kernel configs (the "Performance might
be sub-optimal!" warning is cosmetic — the default Triton config already hits 96% of achievable,
and kyuz0's MI300X fallback patch misses all five of this model's shapes anyway); GPU clocks and
thermals (mclk pinned at top DPM 1258 MHz under load, mem 58C, junction 72C, no throttling);
gpu_memory_utilization and max_num_batched_tokens (no effect on the server); iGPU spillover (the
iGPU holds a constant 828 MiB of desktop and never moves); CPU saturation (~5 of 24 cores, and
both GPUs report 100% busy throughout, so the CPU is not the gate); GGUF/4-bit in vLLM (that is a
llama.cpp asset — for vLLM you would need AWQ/GPTQ, unproven on gfx1201); upgrading the image
(vLLM 0.27.1 tested: baseline unchanged at 24.34, MTP WORSE at 34.66 vs 40.75).

Profiling note: the torch profiler records ZERO GPU kernel events in this image (kineto's ROCm
activity backend produces nothing, with or without cudagraphs), and rocprofv3 only flushes at
process exit while vLLM will not exit under it. `rocprofv3` is present in the image if you want to
retry, but budget real time for it — the working approach was micro-benchmarking kernels directly
against a measured bandwidth ceiling.

The reason it is expensive: on gfx1201 every fast all-reduce backend is arch-gated to CDNA, so TP
falls through to the generic PYNCCL path. Confirmed in the startup log:

    Using ['PYNCCL'] all-reduce backends (in dispatch order) for group 'tp:0' out of potential
    backends: ['NCCL_SYMM_MEM','QUICK_REDUCE','FLASHINFER','CUSTOM','SYMM_MEM','PYNCCL']

Both gates are hard-coded to ["gfx94","gfx95"] in this image: `use_custom_allreduce()` in
vllm/platforms/rocm.py and `supported_archs` in
vllm/distributed/device_communicators/quick_all_reduce.py. No flag or env var changes that.

Knobs. A systemd drop-in does NOT work for these — this is a Quadlet container, so
`[Service] Environment=` lands on the podman process, not inside the container. Shadow the unit:

    mkdir -p ~/.config/containers/systemd/users
    cp /etc/containers/systemd/users/vllm.container ~/.config/containers/systemd/users/
    # add an  Environment=KEY=value  line under [Container]
    systemctl --user daemon-reload && systemctl --user restart vllm

A shadowed unit is a full copy and will not track changes to the baked unit — re-copy after an
image build.

1. `VLLM_SPECULATIVE` — MTP speculative decoding, **ON by default**. The big one: ~1.9 tokens per
   forward pass, so the whole per-token cost is amortised. Measured 2026-08-19: 41.74 tok/s on
   rust code, 40.43 python, 38.72 prose, versus 24.3 with it off. Set to the empty string to
   disable. Greedy output will not be byte-identical to non-speculative — that is expected, see
   the launcher comment; batch shape alone flips the same tokens with no speculation involved.
2. `NCCL_PROTO` — defaults to `Simple`, which MEASURED faster on this box: a 2-rank RCCL
   all-reduce benchmark gave 27.6 us/op for Simple vs 35.0 for auto at the 10 KiB size decode
   actually uses (equal by 1 MiB). Theory suggested the opposite; the theory was wrong. Note it
   also comes from the image's `/etc/profile.d/01-rocm-envs.sh`, which the launcher sources, so
   the launcher re-applies its choice AFTER that source loop — a value assigned before it is
   silently overwritten. Set to the empty string to let RCCL's tuner choose.
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
