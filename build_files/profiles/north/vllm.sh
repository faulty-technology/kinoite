#!/bin/bash
set -ouex pipefail

# vLLM (kyuz0's gfx1201/R9700 ROCm image) + Open WebUI as a rootless Quadlet POD, so the
# two spin up/down together and talk over the pod's shared localhost. Second, independent
# local-LLM stack alongside lemonade (lemonade.sh) — vLLM does batched tensor-parallel serving;
# lemonade does llama.cpp GGUF. They SHARE the model store (see the HF cache volume below).
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by hand with
# `systemctl --user start north-llm-pod`. Runbook and gotchas live in /usr/share/kinoite/vllm.md.

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
# VLLM_MAX_MODEL_LEN, VLLM_GPU_UTIL, VLLM_MAX_BATCHED_TOKENS, VLLM_REASONING_EFFORT, plus the
# three perf experiments NCCL_PROTO, VLLM_FUSE_NORM_QUANT and VLLM_SPECULATIVE (see the comments
# at each, and the "Decode performance" section of vllm.md).
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

# kyuz0's ROCm/vLLM env. The /etc/profile.d/ path is the one that ships — it is NOT a no-op,
# contrary to an earlier note. See docs/runs/2026-09-05-build-comment-consolidation.md#nccl_protosimple-measured-faster.
for f in /opt/scripts/01-rocm-envs.sh /etc/profile.d/01-rocm-envs.sh; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && source "$f"
done

# NCCL_PROTO: pinned to Simple. Measured faster than auto at decode-sized
# all-reduces. Full benchmark table and the ~11% comm-budget context:
# docs/runs/2026-09-05-build-comment-consolidation.md#nccl_protosimple-measured-faster
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
# --max-num-seqs default is 4, NOT kyuz0's 1. Batch-1 decode here is bound by a FIXED per-token
# cost (weights + 128 all-reduces), not by context, so batching amortises it and buys aggregate
# throughput for parallel agent tool calls at ~no single-stream cost; at 1 the log shows real
# requests queueing. VLLM_MAX_SEQS=1 restores kyuz0's single-stream benchmarking behaviour.
#
# MTP speculative decoding, ON at k=4. k saturates in tokens-per-pass after 4. k is NOT capped
# by mtp_num_hidden_layers (that's depth, not width). disable_padded_drafter_batch is removed
# (+19.1% single-stream but crashes at n>=3 concurrent). --no-async-scheduling removed
# (measured 2026-09-03 at k=4: costs nothing). Full details:
# docs/runs/2026-09-05-build-comment-consolidation.md#vllmsh
EXTRA_ARGS=()
SPEC_DEFAULT='{"method":"mtp","num_speculative_tokens":4}'
SPEC="${VLLM_SPECULATIVE-$SPEC_DEFAULT}"
if [ -n "$SPEC" ]; then
    EXTRA_ARGS+=(--speculative-config "$SPEC")

    # Strict tool calling OFF whenever speculation is on — broken together in this image
    # (vllm-project/vllm#44006, fixed upstream 2026-07-04; this 2026-06-13 build is before it).
    # Costs ~15% of MTP decode to bump to a fixed image. Full rationale:
    # docs/runs/2026-09-05-build-comment-consolidation.md#strict-tool-calling-off-while-mtp-is-on
    #
    # With MTP off (VLLM_SPECULATIVE=), strict mode restores itself. An explicit
    # VLLM_ENFORCE_STRICT_TOOL_CALLING in the environment still wins over both.
    export VLLM_ENFORCE_STRICT_TOOL_CALLING="${VLLM_ENFORCE_STRICT_TOOL_CALLING:-0}"
fi

# Prefix caching: ON by default since 2026-08-31. Worth 1.73× end-to-end agentic.
# Overrides an upstream experimental gate for hybrid models (is_prefix_caching_supported
# returns False for attn_type=="hybrid"; Qwen3.8-27B is qwen3_5, i.e. hybrid).
# No quality A/B on vs off. Decision, rationale, and correctness notes:
# docs/runs/2026-09-05-build-comment-consolidation.md#prefix-caching-forced-on-for-hybrid-model
#
# --mamba-cache-mode align is REQUIRED alongside it for a hybrid model.
# Do not enable prefix caching without it.
PREFIX_CACHING="${VLLM_PREFIX_CACHING:-true}"
case "$PREFIX_CACHING" in
    true)  EXTRA_ARGS+=(--enable-prefix-caching --mamba-cache-mode align) ;;
    false) ;;
    *) echo "[vllm-serve] VLLM_PREFIX_CACHING must be true|false, got '$PREFIX_CACHING'" >&2; exit 1 ;;
esac

# Reasoning effort: baked to MEDIUM, down from the model's own default (xhigh).
# Unset = highest effort, not neutral. Thinking tokens cost on every subsequent
# forward pass; at agentic context depth (~70K) context is 64% of the forward pass.
# medium is the conservative middle, not a benchmarked optimum; no quality A/B run.
# The flag is guarded: a bad value yields a restart loop (vLLM exits 2/INVALIDARGUMENT
# on unrecognised args; this unit is Restart=always). Full rationale:
# docs/runs/2026-09-05-build-comment-consolidation.md#reasoning-effort-pinned-to-medium
#
# `high` is NOT a level and must stay out of the case below. The template raises
# on it, and the flag is not validated at startup — every request 400s silently.
REASONING_EFFORT="${VLLM_REASONING_EFFORT-medium}"
if [ -n "$REASONING_EFFORT" ]; then
    case "$REASONING_EFFORT" in
        xhigh|medium|low) ;;
        *) echo "[vllm-serve] VLLM_REASONING_EFFORT must be xhigh|medium|low (or empty to" \
                "leave the model's default), got '$REASONING_EFFORT'" >&2; exit 1 ;;
    esac
    # Glob, not `ls ... | head` — under this script's `set -o pipefail` a non-matching ls fails the
    # whole pipeline, the assignment inherits that, and `set -e` kills the launcher. Which would be
    # the restart loop this guard exists to prevent. `if` keeps the -d test in condition context.
    VLLM_PKG=""
    for d in /opt/venv/lib*/python3*/site-packages/vllm; do
        if [ -d "$d" ]; then VLLM_PKG="$d"; break; fi
    done
    if [ -n "$VLLM_PKG" ] \
       && ! grep -rqsE --include='*.py' 'default[-_]chat[-_]template[-_]kwargs' "$VLLM_PKG"; then
        echo "[vllm-serve] WARNING: this image's vLLM has no --default-chat-template-kwargs, so" >&2
        echo "[vllm-serve] VLLM_REASONING_EFFORT=$REASONING_EFFORT cannot be applied server-side." >&2
        echo "[vllm-serve] Starting at the model's own xhigh default; send chat_template_kwargs" >&2
        echo "[vllm-serve] per request instead. See vllm.md, 'Thinking / the reasoning field'." >&2
    else
        EXTRA_ARGS+=(--default-chat-template-kwargs "{\"reasoning_effort\":\"$REASONING_EFFORT\"}")
    fi
fi

# --gpu-memory-utilization default is 0.80, down from 0.95 on 2026-08-24 after a VRAM OOM.
# At 0.95 the KV cache grew to 344,064 tokens (2.63× context) and left no headroom for
# prefill buffers. 0.80 gives KV 7.87 GiB = 225,652 tokens (1.72× context) with ~7.4 GiB
# per card free. KV at 36.6 KiB/token/card; sizing: KV_GiB ~= 31.86*util - 18.26.
# Hard floor ~0.72: below it KV < max_model_len and vLLM refuses to start.
# Full ledger: docs/runs/2026-09-05-build-comment-consolidation.md#gpu-memory-utilization-lowered-to-080

# --max-num-batched-tokens default is 8192, down from 16384 after a VRAM OOM.
# At 16384 a ~16K prompt was scheduled as a single unchunked step whose bf16 GEMM output
# alone was 538 MiB against ~1.3 GiB headroom (~4.1 GiB non-torch overhead per rank).
# 8192 makes >8K prompts chunk. Costs one extra TTFT chunk on long prompts, nothing at decode.
# Full ledger: docs/runs/2026-09-05-build-comment-consolidation.md#max-num-batched-tokens-lowered-to-8192-after-vram-oom
#
# TP=2 shards per card — the 64 GB total does not pool. The binding constraint is always
# one card's 31.86 GiB. Lowering this moves memory into KV; use VLLM_GPU_UTIL for real margin.

# ${EXTRA_ARGS[@]+...} guard: expanding an empty array is an unbound-variable error under `set -u`
# on bash < 4.4, and this runs in whatever bash the upstream image ships.
exec vllm serve "$VLLM_MODEL" \
    --host 0.0.0.0 --port 8000 \
    --tensor-parallel-size "${VLLM_TP:-2}" \
    --max-num-seqs "${VLLM_MAX_SEQS:-4}" \
    --max-model-len "${VLLM_MAX_MODEL_LEN:-131072}" \
    --gpu-memory-utilization "${VLLM_GPU_UTIL:-0.80}" \
    --max-num-batched-tokens "${VLLM_MAX_BATCHED_TOKENS:-8192}" \
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

### 1b. Decode benchmark
# Baked because the tuned defaults in the launcher (above all num_speculative_tokens) are only
# valid for the image+model pair that was measured, and the doc tells you to re-run the sweep
# after a bump. Without this shipped, "re-measure" means rewriting the harness first, which is
# how a stale default survives for a day. Host-side (talks to the published 127.0.0.1:8000) and
# stdlib-only, so it needs nothing installed.
#
# Method: stream the response and time from the FIRST content token to the LAST. That excludes
# queueing, prefill and TTFT, so the number is pure decode rate — equivalent to the slope method
# used earlier, without needing two runs at different lengths.
cat > /usr/share/kinoite/vllm/bench.py << 'PYEOF'
#!/usr/bin/env python3
"""Decode-throughput bench for the local vLLM server.

    python3 /usr/share/kinoite/vllm/bench.py [max_tokens]

Reports per-workload decode tok/s at batch 1, plus the MTP acceptance length scraped from vLLM's
own spec_decode counters (mean tokens emitted per forward pass — the number that explains the
throughput). See docs/runs/2026-08-22-vllm-speculation-sweep.md for the k sweep this produced.
"""
import json, sys, time, urllib.request

BASE = "http://127.0.0.1:8000"
MAXTOK = int(sys.argv[1]) if len(sys.argv) > 1 else 512

WORKLOADS = {
    "rust":   "Write a complete Rust implementation of a lock-free MPSC queue using atomics, with detailed comments explaining the memory ordering choices at every step.",
    "python": "Write a complete Python implementation of a B-tree with insert, delete, and range-scan, with docstrings and inline comments explaining the split and merge logic.",
    "prose":  "Write a detailed essay explaining how GPU memory bandwidth becomes the limiting factor for autoregressive LLM inference at batch size one, and how speculative decoding changes that.",
}
SPEC_KEYS = ("spec_decode_num_drafts_total",
             "spec_decode_num_draft_tokens_total",
             "spec_decode_num_accepted_tokens_total")


def metrics():
    """spec_decode counters, or {} when speculation is off."""
    try:
        raw = urllib.request.urlopen(BASE + "/metrics", timeout=10).read().decode()
    except Exception:
        return {}
    out = {}
    for line in raw.splitlines():
        if line.startswith("#"):
            continue
        for key in SPEC_KEYS:
            if key in line:
                try:
                    out[key] = out.get(key, 0.0) + float(line.rsplit(" ", 1)[1])
                except (ValueError, IndexError):
                    pass
    return out


def run(prompt):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAXTOK,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
        # Keep thinking off so every run generates the same KIND of tokens; with it on, a run that
        # happens to think longer looks faster or slower for reasons that are not the engine.
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t_first = t_last = None
    n = 0
    usage = None
    with urllib.request.urlopen(req, timeout=900) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            chunk = json.loads(payload)
            if chunk.get("usage"):
                usage = chunk["usage"].get("completion_tokens") or usage
            for ch in chunk.get("choices", []):
                delta = ch.get("delta", {})
                # Field is `reasoning`, NOT `reasoning_content` — this build emits the former
                # (verified 2026-08-24: streaming delta keys are content/reasoning/role/tool_calls).
                # Inert while run() pins enable_thinking:false below, but it is a live trap if that
                # pin is ever removed: usage.completion_tokens counts reasoning tokens, so timing
                # only the content window would divide all tokens by part of the elapsed time and
                # silently inflate tok/s. See vllm.md, "Thinking / the reasoning field".
                if delta.get("content") or delta.get("reasoning"):
                    now = time.perf_counter()
                    if t_first is None:
                        t_first = now
                    t_last = now
                    n += 1
    if t_first is None or n < 2:
        return None
    counted = usage or n
    return (counted - 1) / (t_last - t_first), counted, t_last - t_first


MODEL = json.load(urllib.request.urlopen(BASE + "/v1/models", timeout=30))["data"][0]["id"]
print(f"model={MODEL}  max_tokens={MAXTOK}")

m0 = metrics()
results = {}
for name, prompt in WORKLOADS.items():
    run(prompt)                       # warm-up, discarded
    best = None
    for _ in range(2):
        r = run(prompt)
        if r and (best is None or r[0] > best[0]):
            best = r
    results[name] = best[0]
    print(f"  {name:7s} {best[0]:6.2f} tok/s   ({best[1]} tok in {best[2]:.2f}s)")
m1 = metrics()

print(f"MEAN {sum(results.values()) / len(results):.2f} tok/s")

d  = m1.get(SPEC_KEYS[0], 0) - m0.get(SPEC_KEYS[0], 0)
dt = m1.get(SPEC_KEYS[1], 0) - m0.get(SPEC_KEYS[1], 0)
a  = m1.get(SPEC_KEYS[2], 0) - m0.get(SPEC_KEYS[2], 0)
if d > 0:
    print(f"acceptance_length {1 + a / d:.3f} tokens/forward-pass   "
          f"per_draft_token_rate {a / dt:.3f}   "
          f"(drafts={int(d)} draft_tok={int(dt)} accepted={int(a)})")
else:
    print("acceptance_length n/a (no speculation)")
PYEOF
chmod 0755 /usr/share/kinoite/vllm/bench.py
python3 -c 'import ast,sys; ast.parse(open("/usr/share/kinoite/vllm/bench.py").read())'

### 1c. k sweep harness
# Baked for the same reason bench.py is: vllm.md tells you to re-run the sweep after any image,
# model or flag change, and without a harness "re-run the sweep" means writing the driver first.
# That gap is how num_speculative_tokens=1 survived for a day at a cost of ~42%.
#
# Unlike bench.py this one RESTARTS THE SERVICE, so it shadows the quadlet. It backs up any
# shadow unit you already had rather than clobbering it, and restores from a finally + SIGINT/
# SIGTERM handler so Ctrl-C mid-sweep still puts the box back.
cat > /usr/share/kinoite/vllm/ksweep.py << 'KSWEEPEOF'
#!/usr/bin/env python3
"""Sweep num_speculative_tokens and report the knee.

    python3 /usr/share/kinoite/vllm/ksweep.py              # k = 1..6
    python3 /usr/share/kinoite/vllm/ksweep.py 2 3 4        # only these k
    python3 /usr/share/kinoite/vllm/ksweep.py --tokens 1024 3 4

Runs on the HOST. For each k it shadows vllm.container with an overridden VLLM_SPECULATIVE,
restarts the unit, waits for /v1/models, runs bench.py, and spot-checks correctness. Every other
launcher setting (including disable_padded_drafter_batch) is inherited from the baked default, so
this measures the knee GIVEN the current configuration rather than in isolation.

Budget ~3-4 min per k with a warm compile cache. Restores the previous state on exit, including
on Ctrl-C, and backs up a shadow unit you already had rather than clobbering it.
"""
import argparse, json, os, re, shutil, signal, subprocess, sys, time, urllib.request

HOME = os.path.expanduser("~")
SHADOW_DIR = f"{HOME}/.config/containers/systemd/users"
SHADOW = f"{SHADOW_DIR}/vllm.container"
BACKUP = f"{SHADOW}.ksweep-backup"
BASE = "/etc/containers/systemd/users/vllm.container"
BENCH = "/usr/share/kinoite/vllm/bench.py"
API = "http://127.0.0.1:8000"

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)
def sh(c, **kw): return subprocess.run(c, shell=True, capture_output=True, text=True, **kw)

def spec_default():
    """Read SPEC_DEFAULT out of the baked launcher so the sweep tracks it automatically."""
    try:
        src = open("/usr/share/kinoite/vllm/vllm-serve.sh").read()
        m = re.search(r"^SPEC_DEFAULT='(.+)'$", src, re.M)
        if m:
            return json.loads(m.group(1))
    except Exception:
        pass
    return {"method": "mtp", "num_speculative_tokens": 4}

def save_state():
    if os.path.exists(SHADOW):
        shutil.copy2(SHADOW, BACKUP)
        log(f"backed up your existing shadow unit -> {BACKUP}")

def restore(*_):
    if os.path.exists(BACKUP):
        shutil.move(BACKUP, SHADOW)
        log("restored your original shadow unit")
    elif os.path.exists(SHADOW):
        os.remove(SHADOW)
        log("removed the sweep's shadow unit")
    sh("systemctl --user daemon-reload")
    sh("systemctl --user stop vllm north-llm-pod")
    sh("systemctl --user reset-failed vllm")
    log("restored")

def write_shadow(spec):
    os.makedirs(SHADOW_DIR, exist_ok=True)
    unit = open(BASE).read()
    # Single quotes are load-bearing: systemd strips bare double quotes and vLLM then rejects the
    # mangled JSON with status=2/INVALIDARGUMENT. See vllm.md, knob 1.
    line = "Environment='VLLM_SPECULATIVE=" + json.dumps(spec, separators=(",", ":")) + "'\n"
    unit = unit.replace("\n[Service]", "\n" + line + "\n[Service]", 1)
    open(SHADOW, "w").write(unit)
    sh("systemctl --user daemon-reload")

def restart_and_wait(timeout=1500):
    sh("systemctl --user stop vllm north-llm-pod"); time.sleep(5)
    sh("systemctl --user reset-failed vllm")
    if sh("systemctl --user start vllm").returncode != 0:
        return False, "start command failed"
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            urllib.request.urlopen(f"{API}/v1/models", timeout=5).read()
            return True, f"ready in {int(time.time() - t0)}s"
        except Exception:
            pass
        if sh("systemctl --user is-active vllm").stdout.strip() not in ("active", "activating"):
            j = sh("journalctl --user -u vllm -b --no-pager -o cat").stdout
            bad = [l for l in j.splitlines() if "error" in l.lower()][-3:]
            return False, "unit died: " + " | ".join(x[:200] for x in bad)
        time.sleep(10)
    return False, f"timeout after {timeout}s"

CHECKS = [
    ("count", "Count from 1 to 40, separated by single spaces. Output only the numbers.",
     lambda s: all(str(n) in s for n in range(1, 41))),
    ("arith", "What is 17 multiplied by 23? Reply with only the number.", lambda s: "391" in s),
    ("echo", "Repeat exactly this and nothing else: purple canyon seventeen",
     lambda s: "purple canyon seventeen" in s.lower()),
]

def correctness(model):
    bad = []
    for name, prompt, ok in CHECKS:
        body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}],
                           "max_tokens": 300, "temperature": 0.0,
                           "chat_template_kwargs": {"enable_thinking": False}}).encode()
        req = urllib.request.Request(f"{API}/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            t = json.load(urllib.request.urlopen(req, timeout=300))["choices"][0]["message"]["content"]
            if not ok(t):
                bad.append(name)
        except Exception:
            bad.append(name)
    return "ok" if not bad else "FAIL:" + ",".join(bad)

def run_bench(tokens):
    r = sh(f"python3 {BENCH} {tokens}", timeout=3600)
    mean = re.search(r"MEAN ([0-9.]+) tok/s", r.stdout)
    acc = re.search(r"acceptance_length ([0-9.]+)", r.stdout)
    per = re.search(r"per_draft_token_rate ([0-9.]+)", r.stdout)
    w = {m[0]: float(m[1]) for m in re.findall(r"^  (\w+)\s+([0-9.]+) tok/s", r.stdout, re.M)}
    return {"mean": float(mean.group(1)) if mean else None,
            "accept": float(acc.group(1)) if acc else None,
            "per_draft": float(per.group(1)) if per else None, "workloads": w}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("k", nargs="*", type=int, default=[1, 2, 3, 4, 5, 6])
    ap.add_argument("--tokens", type=int, default=512)
    a = ap.parse_args()

    base = spec_default()
    log(f"base speculative config (from the baked launcher): {json.dumps(base)}")
    log(f"sweeping k={a.k} at {a.tokens} tokens")

    save_state()
    signal.signal(signal.SIGINT, lambda *x: (restore(), sys.exit(130)))
    signal.signal(signal.SIGTERM, lambda *x: (restore(), sys.exit(143)))

    rows = []
    try:
        for k in a.k:
            spec = dict(base, num_speculative_tokens=k)
            write_shadow(spec)
            ok, msg = restart_and_wait()
            log(f"k={k}: {msg}")
            if not ok:
                rows.append({"k": k, "error": msg}); continue
            model = json.load(urllib.request.urlopen(f"{API}/v1/models", timeout=30))["data"][0]["id"]
            b = run_bench(a.tokens)
            c = correctness(model)
            rows.append(dict(k=k, **b, correctness=c))
            log(f"k={k}: MEAN={b['mean']} accept={b['accept']} per_draft={b['per_draft']} {c}")
    finally:
        restore()

    print()
    print("    k   " + "".join(f"{n:>8s}" for n in ("rust", "python", "prose")) +
          f"{'MEAN':>8s}{'accept':>8s}{'per_dft':>9s}  correctness")
    best = None
    for r in rows:
        if r.get("error"):
            print(f"    {r['k']:<3d} ERROR: {r['error'][:60]}"); continue
        w = r["workloads"]
        print(f"    {r['k']:<3d} " + "".join(f"{w.get(n, 0):8.2f}" for n in ("rust", "python", "prose")) +
              f"{r['mean']:8.2f}{r['accept'] or 0:8.3f}{r['per_draft'] or 0:9.3f}  {r['correctness']}")
        if r["correctness"] == "ok" and (best is None or r["mean"] > best["mean"]):
            best = r
    if best:
        print()
        print(f"    best MEAN at k={best['k']} ({best['mean']:.2f} tok/s)")
        print("    The knee is where the gain per extra k stops paying for the draft compute --")
        print("    read the per_dft column, not just MEAN, and remember wasted drafts cost more")
        print("    as batch size rises. See vllm.md, 'Decode performance'.")
    print()
    print("    NOT persisted. To adopt a k, set it in a shadowed unit (vllm.md 'Knobs') or change")
    print("    SPEC_DEFAULT in build_files/profiles/north/vllm.sh and rebuild.")

main()
KSWEEPEOF
chmod 0755 /usr/share/kinoite/vllm/ksweep.py
python3 -c 'import ast,sys; ast.parse(open("/usr/share/kinoite/vllm/ksweep.py").read())'

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
# HIP_VISIBLE_DEVICES. See docs/reference/gpu-topology.md.
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
# Restart=always, not on-failure. vLLM exits cleanly (0) on EngineDeadError, so
# on-failure sees success and does nothing. Full incident: docs/runs/2026-09-05-build-comment-consolidation.md#restartalways-not-on-failure
Restart=always
RestartSec=10

# First start pre-pulls the ~32 GB image (ExecStartPre below) AND vLLM downloads the ~27 GB model;
# both must finish within this window, so give it an hour of headroom.
TimeoutStartSec=3600

# Pre-pull the image with plain `podman pull`, only when missing. Load-bearing: the implicit
# pull inside `podman run` is hard-capped at 5 min under systemd — confirmed killing a slow
# first pull at exactly 5m03s on the 32 GB image.
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

### 3. On-box runbook
# The box won't have this repo checked out when something breaks. Source is docs/how-to/vllm.md.
install -D -m 0644 /ctx/docs/how-to/vllm.md /usr/share/kinoite/vllm.md
