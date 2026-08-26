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
# --max-num-seqs default is 4, NOT kyuz0's 1. Batch-1 decode here is bound by a FIXED per-token
# cost (weights + 128 all-reduces), not by context, so batching amortises it and buys aggregate
# throughput for parallel agent tool calls at ~no single-stream cost; at 1 the log shows real
# requests queueing. VLLM_MAX_SEQS=1 restores kyuz0's single-stream benchmarking behaviour.
#
# MTP speculative decoding, ON at k=4 — the single biggest win on this box, emitting ~3.4 tokens
# per forward pass so the whole per-token cost is amortised across them. Full sweep 2026-08-26
# (single stream, 512 tok): k=2 47.2, k=3 52.1, k=4 55.9, k=5 54.4, k=6 51.7 tok/s mean. Tokens per
# pass saturates after k=4 (3.35 -> 3.48 -> 3.47), so past it you buy draft compute and no tokens.
# CAVEAT: the k=4 gain is single-stream and code-shaped (python +12%, rust +9%, prose flat to -0.4%);
# at concurrency >=2 k=3 and k=4 are within noise. This box is single-user, hence k=4. Sweep table
# and how to re-measure after an image bump: vllm.md, "Decode performance".
# VLLM_SPECULATIVE= (explicitly empty) turns speculation off.
#
# TWO TRAPS, both already paid for once:
#   - k is NOT capped by the checkpoint's mtp_num_hidden_layers. That field is the draft head's
#     DEPTH; vLLM runs the one module autoregressively k times. Misreading it as a cap pinned k=1
#     and cost ~42% of achievable throughput. The real constraint (vllm/config/speculative.py:
#     765-780) is only a divisibility rule when k > n_predict, and n_predict=1 divides cleanly.
#   - Do NOT gate correctness on byte-identical greedy output. Batch shape alone flips tokens with
#     no speculation involved (FP8 near-ties; argmax follows reduction order), so the
#     non-speculative baseline is not shape-stable either and the test cannot pass. Spot-check
#     semantics instead.
#
# Costs ~1 extra layer of VRAM. Do not chase a newer image for this: vLLM 0.27.1 measured WORSE
# (MTP 34.66 vs 40.75 on an identical prompt, with an unchanged baseline).
#
# disable_padded_drafter_batch:true was ON by default from 2026-08-22 and is now OFF (removed, so
# upstream's false applies). IT CRASHES THE ENGINE UNDER CONCURRENCY — bisected on-box 2026-08-24
# with four parallel 16K-token prompts:
#     TRUE : n=2 OK | n=3 CRASH (4 assertions) | n=4 CRASH
#     FALSE: n=4 OK, 12/12 across three rounds, 0 assertions, 0 restarts
# The drafter dies preparing a batched step:
#     vllm/v1/spec_decode/llm_base_proposer.py:1082 in prepare_inputs
#     assert common_attn_metadata.seq_lens_cpu_upper_bound is not None   -> AssertionError
# which takes EngineCore with it, so every in-flight request 500s and the server exits. --max-num-seqs
# is 4, i.e. the flag was incompatible with the concurrency this same file configures. The 2026-08-22
# benchmark never caught it because every arm was measured SINGLE-STREAM.
#
# What we gave up: +19.1% decode (64.54 vs 54.21 tok/s mean, control reproduced three times at
# 54.20/54.21 against the recorded 54.22). Acceptance length was UNCHANGED (3.006 vs 3.020), so it
# was never better speculation, just per-forward-pass padding overhead removed. Biggest gain on the
# weakest workload — prose 48.90 -> 62.16 (+27%). Correctness spot-checks passed on every arm.
#
# THE OTHER SIDE OF THE TRADE was keeping the flag and capping concurrency at the tested-safe
# VLLM_MAX_SEQS=2. DECIDED AGAINST, deliberately, 2026-08-24: concurrency is worth more here than
# 19.1% of single-stream decode, because the box exists to serve parallel agent tool calls and
# --max-num-seqs 4 was chosen for exactly that reason. This is a settled choice, not a default
# nobody looked at — do not "restore" the flag on the strength of the 08-22 throughput table alone.
# If you ever do want that trade back, it is BOTH lines together or neither:
#     Environment='VLLM_SPECULATIVE={"method":"mtp","num_speculative_tokens":3,"disable_padded_drafter_batch":true}'
#     Environment=VLLM_MAX_SEQS=2
#
# It WAS coupled to --no-async-scheduling below (upstream requires that pairing; the flag on its own
# was never tested). With the flag gone that coupling no longer applies, and --no-async-scheduling
# COSTS 3.2% by itself (52.48 vs 54.21, measured as its own arm). So there is likely ~3% sitting
# there for whoever re-tests async scheduling with plain MTP — UNTESTED, hence left as-is: it is
# still applied whenever speculation is on, which is the conservative choice, not a measured one.
EXTRA_ARGS=()
SPEC_DEFAULT='{"method":"mtp","num_speculative_tokens":4}'
SPEC="${VLLM_SPECULATIVE-$SPEC_DEFAULT}"
if [ -n "$SPEC" ]; then
    EXTRA_ARGS+=(--speculative-config "$SPEC" --no-async-scheduling)

    # Strict tool calling OFF whenever speculation is on — they are broken together in this
    # image, and it is the speculation we want to keep. Upstream bug, fixed on 2026-07-04 by
    # vllm-project/vllm#44297, which this 2026-06-13 build predates by three weeks.
    #
    # An image WITH the fix already exists and we are deliberately not taking it: kyuz0's `dev` /
    # `rocm7.14.0-torch2.11.0-vllm0.27.1` tags are a 2026-08-12 build of vLLM 0.27.1, and 0.27.1
    # is well past the fix (first release after it was 0.25.0 on 07-11). But 0.27.1 is the image
    # already measured ~15% SLOWER at MTP decode — 34.66 vs 40.75 on an identical prompt, see the
    # "Decode performance" note — so upgrading trades 15% of throughput to regain a tool-calling
    # guarantee we barely use. This knob is the cheaper side of that trade. Revisit when a build
    # lands that is both post-07-04 AND not a decode regression. (Tags checked 2026-08-23; the
    # date-stamped tags stop at 20260613-143121, the newer builds are only under dev/version tags,
    # so `skopeo inspect` the tag rather than trusting the tag list to be chronological.)
    #
    # THE FAILURE, end to end. Open WebUI defaults to NATIVE function calling, so an ordinary
    # chat carries `tools` (its builtin web_search among them). VLLM_ENFORCE_STRICT_TOOL_CALLING
    # defaults to True in this build (envs.py:204), so the tool parser hands the request an
    # xgrammar STRUCTURAL TAG (tool_parsers/abstract_tool_parser.py get_structural_tag) to
    # constrain tool-call syntax. Reasoning models are supposed to be exempt until the model
    # leaves its thinking block: should_advance (v1/structured_output/__init__.py) defers the FSM
    # advance by one step at the </think> boundary, "advancing on the closing boundary token can
    # accept tokens that still belong to the reasoning stream". But that deferral has an explicit
    # escape hatch for speculative decoding + STRUCTURAL_TAG which returns True instead — so with
    # MTP on, the FSM is advanced ON the boundary step and fed the whole accepted batch,
    # reasoning text and closing tag included. xgrammar rejects it and the request dies 500:
    #   backend_xgrammar.py:162 Failed to advance FSM ... for tokens 248069     <- 248069=</think>
    #   scheduler.py:1531 grammar rejected tokens [10429, 13, 198, 248069]      <- " honest.\n</think>"
    # Batches are always 1+num_speculative_tokens long, which is the tell. Reproduced on-box
    # 2026-08-23 at 3/12 requests; the identical signature, same token id, is upstream #44006.
    #
    # Setting this to 0 makes get_structural_tag return None, so no grammar is attached and the
    # boundary is never reached. Tool calls fall back to the qwen3_coder parser's
    # extract_tool_calls — how vLLM did tool calling before strict mode existed — so we lose
    # grammar-guaranteed syntax, not the feature. Only the `tools` path was ever affected:
    # response_format/json_schema takes the ordinary deferral (no structural tag) and measured
    # clean, as did plain chat.
    #
    # Coupled to speculation on purpose. Set VLLM_SPECULATIVE= to turn MTP off and strict tool
    # calling comes back by itself, because without spec decode the deferral is correct. An
    # explicit VLLM_ENFORCE_STRICT_TOOL_CALLING in the environment still wins over both. Delete
    # this whole block once the image carries a build newer than 2026-07-04.
    export VLLM_ENFORCE_STRICT_TOOL_CALLING="${VLLM_ENFORCE_STRICT_TOOL_CALLING:-0}"
fi

# Prefix caching: OPT-IN, default off. Set VLLM_PREFIX_CACHING=true to enable.
#
# Worth it for agentic coding, where every request repeats a big fixed prefix (system prompt,
# open files). Measured 2026-08-22 with a ~6K-token shared prefix and six different questions:
# TTFT collapses from a flat 3.33 s per request to 3.47 s once, then 0.47 s — a 7.4x speedup on
# every request after the first. Decode rate is unchanged (53.77 vs 54.21, inside noise), which
# is the expected shape: this is a PREFILL optimisation and costs nothing at decode. Stacks
# cleanly with the drafter flag above (64.11 tok/s AND 7.7x TTFT together).
#
# Off by default anyway, because upstream gates it: is_prefix_caching_supported (config/model.py)
# returns False for any attn_type == "hybrid" model with "Hybrid models do not support prefix
# caching since the feature is still experimental" — logged at DEBUG, which is why nothing ever
# explained it. Qwen3.8-27B is qwen3_5, i.e. hybrid, so we are overriding an experimental gate.
# Correctness spot-checks passed, but one afternoon is not enough to default it on.
#
# --mamba-cache-mode align is REQUIRED alongside it for a hybrid model (in this build: "only
# cache the mamba state of the last token of each scheduler step and when the token is at
# position i * block_size"). Do not enable prefix caching without it.
PREFIX_CACHING="${VLLM_PREFIX_CACHING:-false}"
case "$PREFIX_CACHING" in
    true)  EXTRA_ARGS+=(--enable-prefix-caching --mamba-cache-mode align) ;;
    false) ;;
    *) echo "[vllm-serve] VLLM_PREFIX_CACHING must be true|false, got '$PREFIX_CACHING'" >&2; exit 1 ;;
esac

# Reasoning effort: baked to MEDIUM, down from the model's own default, 2026-08-25.
#
# An unset knob here is not "neutral" — Qwen3.8's chat template resolves
# `reasoning_effort|default('xhigh')`, and xhigh is the HIGHEST of the three levels
# ('xhigh' | 'medium' | 'low'; 'high' is accepted and aliased onto 'xhigh'). Nothing in this stack
# was setting it and Open WebUI sends no chat_template_kwargs at all, so every real request ran at
# maximum effort by omission. Only bench.py and ksweep.py escaped it, by pinning thinking off.
#
# TWO COSTS, and the second is the one that makes this a throughput knob rather than a taste one:
#   - At xhigh the model will spend most of a small max_tokens budget inside <think> and return
#     little or no content. That reads as a bug and is not one.
#   - Reasoning tokens land in the context and are then re-read on EVERY subsequent forward pass.
#     Against the context model measured 2026-08-25 (vllm.md, "Decode performance"),
#     ms/pass = 1.186*ctxK + 47.2, so at the ~70K an agentic loop actually runs at, context is 64%
#     of the forward pass. Thinking is not paid for once; it is paid for again by every turn after
#     it. That is the same arithmetic behind "context management beats kernel tuning" there.
#
# UNMEASURED, and deliberately so: medium is the conservative middle, NOT a benchmarked optimum,
# and no quality A/B has been run on this box. The decode tables in vllm.md are untouched by it —
# they were all measured with `enable_thinking: false`. If a task regresses, put it back with
# Environment=VLLM_REASONING_EFFORT=xhigh in a shadowed unit (see the header note), or let the
# client ask per request: request-level chat_template_kwargs OVERRIDE the server default, which is
# also why the two harnesses' thinking-off pins still hold.
#
# THE FLAG IS GUARDED, because getting it wrong is a restart LOOP rather than an error anyone
# notices: this unit is Restart=always and vLLM exits 2/INVALIDARGUMENT on an unrecognised
# argument. Upstream also shipped a window where the flag PARSED but was silently ignored —
# "[Frontend][Bugfix] respect server-level default chat template kwargs" merged 2026-01-05, which
# this 2026-06-13 build is comfortably past, so it should both parse AND apply here. The grep is
# the same trick the "Tool calling" section of vllm.md uses to test an image for a fix. If it ever
# fires the server still starts — at the model's xhigh. VLLM_REASONING_EFFORT= (explicitly empty)
# skips the flag entirely, for the same reason NCCL_PROTO= and VLLM_SPECULATIVE= do.
#
# Do NOT "simplify" this to `vllm serve --help | grep`: this version's help is GROUPED and prints
# only section names, so grepping it finds nothing and reads as proof the flag is absent. That trap
# is already recorded in notes/kinoite-north-validation.md. `--help=all` is the working form, but
# it costs a full vLLM import on every start, which the source grep does not.
REASONING_EFFORT="${VLLM_REASONING_EFFORT-medium}"
if [ -n "$REASONING_EFFORT" ]; then
    case "$REASONING_EFFORT" in
        xhigh|high|medium|low) ;;
        *) echo "[vllm-serve] VLLM_REASONING_EFFORT must be xhigh|high|medium|low (or empty to" \
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

# --gpu-memory-utilization default is 0.80, DOWN from 0.95 on 2026-08-24.
#
# 0.95 is a "fill the card" instruction: vLLM claims that fraction and hands every leftover byte to
# the KV cache, so the KV cache expands until it has eaten the headroom a large prefill needs. At
# 0.95 it had reached 344,064 tokens — 2.63x the 128K max context — while sitting 8% used. That is
# what left 0 bytes for the 538 MiB buffer in the OOM below. Lowering it is the only knob that
# reserves headroom the KV cache cannot reclaim (see max-num-batched-tokens: lowering THAT just
# moves memory into KV).
#
# Measured on-box 2026-08-24 at 0.80: KV 7.87 GiB = 225,652 tokens, still 1.72x a full 128K
# request; idle VRAM 30.09 -> 24.41 GiB/card, freeing ~7.4 GiB/card (~14.9 GB across the pair)
# for a second smaller model alongside this one. KV bytes/token measured at 36.6 KiB/token/card,
# so pick a value with:  KV_GiB ~= 31.86*util - 18.26
#
# HARD FLOOR ~0.72. The KV cache must hold at least max_model_len (131,072) tokens or vLLM refuses
# to start; 0.70 lands at ~115,900 and will not boot. 0.80 keeps a real band above that rather
# than sitting on the limit. Costs nothing measurable — concurrency is bounded by --max-num-seqs 4
# long before 225K KV tokens are in play.

# --max-num-batched-tokens default is 8192, DOWN from 16384 after a VRAM OOM on 2026-08-24.
#
# THE FAILURE. A 16,146-token prompt arrived and the scheduler put the whole thing in ONE prefill
# step (dump_input showed total_num_scheduled_tokens=16146, under the 16384 budget) — so "chunked
# prefill is enabled" chunked nothing. Both TP ranks then died in w8a8_triton_block_scaled_mm
# allocating that step's bf16 GEMM output, 16146 x 17472 x 2B = 538.00 MiB exactly:
#   torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 538.00 MiB.
#   GPU 1 has a total capacity of 31.86 GiB of which 0 bytes is free.
# The KV cache was 8% used, so this was NOT context length or concurrency. Per-card ledger at the
# time: weights 14.68 + KV 10.96 + graph capture 0.81 + non-torch (HIP ctx, RCCL, hipBLASLt/triton)
# ~4.12 = ~30.6 of 31.86, leaving ~1.3 GiB for the whole prefill activation set.
#
# NOTE the 64 GB does not help: TP=2 shards weights/KV/activations per card, it does not pool them.
# The binding constraint is always one card's 31.86 GiB, and the ~4.1 GiB of non-torch overhead is
# DUPLICATED per rank rather than shared.
#
# 8192 halves the largest possible prefill step, so that buffer is ~269 MiB and a >8K prompt
# actually chunks. Costs one extra chunk of TTFT on long prompts, nothing at decode. Verified
# on-box 2026-08-24: a 16,030-token prompt (the size that OOMed) answers in 7 s.
#
# IT DOES NOT, BY ITSELF, BUY MUCH HEADROOM — vLLM profiles at max_num_batched_tokens and hands
# whatever is left to the KV cache, so lowering it just moved memory into KV: 10.96 -> 12.01 GiB,
# 308,317 -> 344,064 tokens. Against a ledger-derived ~30.6 GiB/card before, measured idle after is
# 28.5 GiB/card — call it ~1-2 GiB gained, and the real win is that the peak step is half the size
# rather than the headroom. If a bigger GUARANTEED margin is wanted, that is
# VLLM_GPU_UTIL (0.95 -> 0.90, ~1.6 GiB/card that KV cannot reclaim); concurrency is 2.62x the
# 128K context against --max-num-seqs 4, so there is plenty to give back. Also unset and worth a
# try: PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True, which targets the 786 MiB that was
# reserved-but-unallocated (fragmentation) at the moment of the OOM. Both need [Container]
# Environment= in a shadowed unit — see the header note.

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
throughput). See "Decode performance" in vllm.md for the k sweep this produced.
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
# Restart=ALWAYS, not on-failure. Load-bearing distinction, learned from the 2026-08-24 OOM: when
# a worker dies, EngineCore raises EngineDeadError and the API server shuts itself down CLEANLY —
# container exit 0, systemd records Result=success. on-failure sees a successful exit and does
# nothing, so the box sat with vLLM dead and Open WebUI happily serving 500s against it. Only
# `always` recovers. RestartSec gives podman time to tear the old container down first.
Restart=always
RestartSec=10

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

Starting the pod brings both containers with it: podman 5.8.4's Quadlet gives the POD service
`Wants=` + `Before=` its members, and each MEMBER `BindsTo=` + `After=` the pod. So either
direction works — `systemctl --user start vllm` starts the pod too, and stopping the pod tears
both members down through that `BindsTo`.

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
parser, reasoning effort pinned to `medium`. FP8 is 8-bit — NOT the 4-bit AWQ path. Other knobs are
env-overridable: VLLM_TP, VLLM_MAX_SEQS, VLLM_MAX_MODEL_LEN, VLLM_GPU_UTIL,
VLLM_MAX_BATCHED_TOKENS, VLLM_REASONING_EFFORT (see "Thinking / the reasoning field" below), plus
the perf knobs NCCL_PROTO / VLLM_FUSE_NORM_QUANT / VLLM_SPECULATIVE (see "Decode performance").

A different model family means re-checking the reasoning-effort pin as well as the parsers: the
level names are Qwen3.8's, and a template that does not take a `reasoning_effort` kwarg will just
ignore it rather than fail.

## Decode performance

All measured on-box, Qwen/Qwen3.8-27B-FP8, TP=2, batch 1.

    MTP k=4 (CURRENT default)                             55.9 mean         (2026-08-26)
    k=3 + drafter-batch (flag gone 08-24)                 62.2 - 67.1 tok/s (2026-08-22)
    with MTP k=3 (previous default)                       48.9 - 58.3       (2026-08-20/22)
    with MTP k=1 (older default)                          36.8 - 39.2       (2026-08-20)
    without MTP                                           24.3              (2026-08-19)

THE DRAFTER-BATCH FLAG, measured 2026-08-22 (five arms, fresh load each, correctness clean;
control reproduced 54.20/54.21 against the 54.22 recorded two days earlier):

    arm                              MEAN    vs ctl   accept   rust    python  prose
    control (k=3)                    54.21     --     3.020    55.42   58.29   48.90
    --no-async-scheduling alone      52.48    -3.2%   3.000     --      --      --
    + disable_padded_drafter_batch   64.54   +19.1%   3.006    64.37   67.10   62.16   <- default
    + prefix caching as well         64.11   +18.3%   2.975    63.52   69.14   59.67

Acceptance is flat, so the gain is padding overhead removed, not better speculation. The
scheduling arm was run alone so the headline is quoted net of its -3.2%.

K SWEEP under the current default (2026-08-22, `ksweep.py 1 2 3 4 5 6`, one run per k):

    k       rust  python   prose    MEAN  accept  per_dft
    1      48.67   49.18   46.17   48.00   1.870    0.870
    2      59.39   61.54   55.22   58.72   2.516    0.758
    3      64.43   67.14   62.15   64.57   3.006    0.669   <- default
    4      65.95   72.03   59.40   65.79   3.277    0.569
    5      59.32   72.85   55.45   62.54   3.397    0.479
    6      65.44   67.45   53.10   61.99   3.587    0.431

k=4 wins MEAN by 1.9% and is still the wrong default: per_dft 0.669 -> 0.569 means 43% of drafts
are wasted (costlier as batch rises, and this box runs --max-num-seqs 4), it regresses the worst
workload (prose 62.15 -> 59.40), and 1.9% is inside this harness's noise — k=5/k=6 are
non-monotonic. One run per k shows the shape, not a 2% difference. Re-run with `ksweep.py`.

k=3 does NOT cost anything at batch >1, which was the thing worth checking before making it the
default — speculation wastes compute when it guesses wrong, and that waste is normally what makes
big k a bad idea on a server. Measured 2026-08-20, 4 concurrent requests x 384 tokens, released
from a barrier so they genuinely overlap, `ignore_eos` so every stream is the same length, median
of 3 reps:

    metric                        k=1      k=3      gain
    single stream                 40.76    67.58    +66%
    aggregate, 4 concurrent      139.02   187.11    +35%
    per-stream while batched     33.2-37.6 48.0-59.7
    ~9.5k-token prompt            33.14    47.55    +43%
    ~38k-token prompt             20.83    29.08    +40%

Correctness gate (counting 1-40, 17*23, exact-word echo) passes at k=3.

Note those single-stream figures are HIGHER than the k-sweep table above (67.58 vs 54.22) because
`ignore_eos` forces the model past its natural stop into low-entropy filler, which MTP predicts
unusually well. That is fine for an A/B where both arms do it, but it is not the number to quote.
The honest single-stream figure is the sweep table's.

CONTEXT IS NOT FREE ONCE YOU SPECULATE. The "dead flat in context" result below is about the
NON-speculative baseline and still holds there. With MTP on, decode falls off hard with prompt
depth — 67.6 short, 47.6 at ~9.5k, 29.1 at ~38k (same method, k=3). Both arms decay by the same
proportion, so k=3 stays ~40% ahead everywhere, but do not quote a short-prompt tok/s as what an
agent with a full context window will see.

THE CONTEXT COST, MEASURED IN SITU 2026-08-25. The line above says "falls off hard"; this says by
how much. Fitted against a live agentic workload (single stream throughout, one request growing
its own context), reading `Drafted throughput`/k out of the `metrics.py:116` log line to get the
target-model forward pass directly — that is the number that is deterministic in context depth,
unlike tok/s, which also carries acceptance-length noise:

    ms/forward_pass = 1.186 * (context in K tokens) + 47.2

55 points fitted over 45-58K, then VALIDATED against 41 further points at 62-70K collected after
an unrelated intervention: mean residual -0.09 ms (-0.1%), worst |residual| 1.6 ms. Convert with
`tok/s = 1000 * acceptance_length / ms_per_pass`; acceptance ran 2.5-2.8 on real prose+code.

    ctx     ms/pass   tok/s @ acc 2.8
      20K      71          39
      40K      95          30
      70K     130          22
     128K     199          14

AT 70K THE CONTEXT TERM IS 83 OF THE 130 ms — 64% of the forward pass. Past ~40K the KV, not the
weights, is the thing you are paying for, which inverts the advice in the budget breakdown below:
that ledger is the ctx->0 intercept, and it stops being the whole story exactly where agents live.
The practical consequence is that CONTEXT MANAGEMENT BEATS KERNEL TUNING HERE — holding a working
context at 20K instead of 70K is ~1.8x decode for free, more than the drafter-batch flag (+19.1%)
and the k=1->3 move (+35%) put together, and it needs no image, no flag and no measurement.

Do NOT extrapolate the fit below its range: the 47.2 ms intercept implies ~64 tok/s at zero
context against a measured 54.22, so it is optimistic by ~15% once context stops dominating.
Quote it for 40-130K and use the sweep table for short prompts.

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

MTP matters precisely because it does not require explaining that ~15 ms: emitting ~3.0 tokens per
forward pass amortises the whole budget regardless of what it is made of. That is also why raising
k pays so well here — the fixed cost per pass is unusually large, so every extra token that rides
along on the same pass is nearly free.

DEAD ENDS — all eliminated by measurement on this box, do not re-chase without new evidence:
NCCL_PROTO / all-reduce protocol (comm is only 11% of the budget); context length (flat, above);
cudagraph capture (CUDAGraphMode.NONE changed nothing); FP8 kernel configs (the "Performance might
be sub-optimal!" warning is cosmetic — the default Triton config already hits 96% of achievable,
and kyuz0's MI300X fallback patch misses all five of this model's shapes anyway); GPU clocks and
thermals (now settled by a controlled A/B, see below — +43% sclk bought 0.0%);
gpu_memory_utilization and max_num_batched_tokens (no effect on the server); iGPU spillover (the
iGPU holds a constant 828 MiB of desktop and never moves); CPU saturation (~5 of 24 cores, and
both GPUs report 100% busy throughout, so the CPU is not the gate); bumping to a newer STOCK
vLLM (0.27.1 tested — kyuz0's own `dev` tag: baseline unchanged at 24.34, MTP WORSE 34.66 vs 40.75).

GPU CLOCKS AND THERMALS, re-opened and re-closed 2026-08-25. The old evidence for this dead end
(mclk top DPM, mem 58C, junction 72C, no throttling) WENT STALE when the 235 W power cap landed in
tuning.sh, and the box now looks alarming under load: both cards pinned at exactly 234/235 W,
`THROTTLE_STATUS: THROTTLED` continuously, hotspot 88-93C, and sclk held at ~2360 MHz against a
~3360 MHz DPM ceiling. That is a real 43% clock deficit and it is NOT costing throughput.

Settled by direct A/B on a live workload rather than by argument. Applying an aggressive
`FAN_CURVE` (see tuning.sh) at an UNCHANGED 235 W cap moved every hardware number and no
performance number:

    hotspot      88-93C   ->  70-78C
    socket power 234/235W ->  184-203W   (cap stops binding entirely)
    sclk         ~2360MHz ->  ~3370MHz   (+43%, at the DPM ceiling)
    ms/pass      121.5    ->  122.0      (matched context; mean residual -0.09 ms over 41 points)

THE MECHANISM IS LEAKAGE, NOT PERFORMANCE. At 90C the cards leak enough extra current to pin
themselves against the cap, which clamps clocks; cooling them drops leakage ~45 W/card, which
releases the cap, which lets clocks rise — and none of it matters, because batch-1 decode is
memory-bandwidth bound and `mclk` sat at top DPM 1258 MHz throughout, before AND after. GFX clock
is not on the critical path at batch 1. Neither is the power cap: do not raise it hoping for
tok/s, and do not let a THROTTLED flag or a 90C hotspot send you back here.

THE TRAP THAT MADE THIS LOOK LIKE A REGRESSION, because it will catch the next person too: an
in-flight request at 58K context was compared against the fresh-load short-prompt sweep figure,
which is exactly the "compare from a fresh load at a fixed prompt" trap flagged under
"Re-measuring". It manufactured a ~17 ms/pass phantom deficit out of nothing but context depth.
Fit the context model above and compare against IT, or compare two runs at the same depth.

Keep the fan curve anyway — it is worth ~18C and ~90 W across the pair for identical work, which
is a thermal and efficiency win. It is just not a throughput knob, and tuning.sh says so.

THAT DEAD END COVERS STOCK VERSION BUMPS ONLY — not the gfx1201-PATCHED builds
(stilldeadcode/vllm-radiance, tcclaviger/vllm), which ship hand-written kernels. Neither has been
run on this box; the evaluation and the one reason still worth chasing (radiance's GDN kernel vs
the ~15 ms below) live in notes/kinoite-north-validation.md. Note radiance's prefix-caching and
drafter-batch flags turned out to be flags THIS image already had — both adopted above.

WHY PREFIX CACHING IS OFF (answered 2026-08-22): nothing disables it — it is never enabled,
because the model is hybrid and upstream gates the feature as experimental. The reason is logged
at logger.debug, which is why it never showed up. How to turn it on: knob 5 below.

4-BIT IN vLLM — the obvious next lever, and it is weaker than it looks for THIS model. The bytes
you actually read per token are what matter, and most 4-bit repackagings of Qwen3.8-27B barely
shrink it, because 48 of the 64 layers are Gated DeltaNet and quantisers leave them alone:

    BF16                             55.6 GB
    FP8 (what we run)                27.8 GB
    AWQ W4A16 (barrydeen)            27.8 GB   <- identical to FP8; GDN layers kept BF16. No win.
    MXFP4 (Quark)                    23.3 GB   1.19x
    W4A16 AutoRound GPTQ             ~19.5 GB  1.43x
    GGUF IQ4_XS (llama.cpp only)     14.2 GB   1.96x

So "switch to AWQ" is a trap: same bytes, worse numerics. Only the AutoRound W4A16 repack is worth
an experiment on the vLLM side, and even then the ~15 ms fixed cost above does not shrink with it —
27.8 -> 19.5 GB moves the GEMV term 21.5 -> 15.1 ms, i.e. 41 -> 34.6 ms, only +19% non-speculative.
Stacked on k=3 it is worth more, but it is a download and a numerics risk for maybe +15%, whereas
the k sweep was free. Do the cheap thing first.

Profiling note: the torch profiler records ZERO GPU kernel events in this image (kineto's ROCm
activity backend produces nothing, with or without cudagraphs), and rocprofv3 only flushes at
process exit while vLLM will not exit under it. `rocprofv3` is present in the image if you want to
retry, but budget real time for it — the working approach was micro-benchmarking kernels directly
against a measured bandwidth ceiling.

### Re-measuring

`bench.py` is baked next to the launcher. It runs on the HOST against the published port, uses
only the stdlib, and needs no arguments:

    python3 /usr/share/kinoite/vllm/bench.py            # 512-token runs
    python3 /usr/share/kinoite/vllm/bench.py 1024

It prints decode tok/s per workload (timed first-content-token to last, so prefill and TTFT are
excluded) and the MTP acceptance length read from vLLM's own `/metrics`.

To redo the k sweep, do NOT drive it by hand — `ksweep.py` is baked next to it and does the whole
thing, including restoring your state on Ctrl-C:

    python3 /usr/share/kinoite/vllm/ksweep.py            # k = 1..6, ~3-4 min each
    python3 /usr/share/kinoite/vllm/ksweep.py 3 4        # just the two that matter
    python3 /usr/share/kinoite/vllm/ksweep.py --tokens 1024 3 4

It shadows the quadlet itself (backing up one you already have), restarts vLLM per k, runs
`bench.py`, correctness-gates each row, and prints the table. It reads `SPEC_DEFAULT` out of the
baked launcher, so it always sweeps k around whatever the current default config is rather than in
isolation. Nothing it does persists — adopting a k means editing `SPEC_DEFAULT` and rebuilding.

One run per k is enough to see the shape but NOT to separate rows a couple of percent apart; run
the two candidates several times before acting on a small difference.

Two traps when comparing numbers: generation slows as the KV cache fills, so always compare from a
fresh load at a fixed prompt; and a run that happens to emit `<think>` blocks is not comparable to
one that does not, which is why the harness pins `enable_thinking: false`.

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

1. `VLLM_SPECULATIVE` — MTP speculative decoding, **ON by default at k=4**: 55.9 tok/s mean
   single-stream, versus 52.1 at k=3 and 24.3 with speculation off (2026-08-26 sweep; the
   `disable_padded_drafter_batch` numbers below predate its removal on 08-24). Empty string
   disables it. To override — **the single quotes are load-bearing**:

       Environment='VLLM_SPECULATIVE={"method":"mtp","num_speculative_tokens":4,"disable_padded_drafter_batch":true}'

   Without them systemd strips the inner double quotes, vLLM gets `{method:mtp,...}`, and the unit
   dies with `status=2/INVALIDARGUMENT`. The launcher echoes the value at startup as
   `[vllm-serve]` — check `journalctl --user -u vllm` if an override seems to be ignored.

   `--no-async-scheduling` is added whenever speculation is on; that pairing is what was measured.
   Do not decouple without re-measuring (the scheduling flag alone costs 3.2%, and the drafter
   flag alone was never tested).

   `num_speculative_tokens` is NOT capped by `mtp_num_hidden_layers` — that is the draft head's
   depth, not the speculation width. Greedy output will not be byte-identical to non-speculative;
   that is expected, batch shape alone flips the same tokens.
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
5. `VLLM_PREFIX_CACHING=true` — **opt-in, off by default.** For agentic coding, where every
   request repeats a big fixed prefix. Measured 2026-08-22 (~6K-token shared prefix, six
   questions): TTFT goes from a flat 3.33 s per request to 3.47 s once, then **0.47 s — 7.4x** on
   every request after. Decode unchanged; stacks with the drafter flag. The launcher adds the
   required `--mamba-cache-mode align` automatically.

   Not the default because it overrides an upstream gate: `is_prefix_caching_supported`
   (`config/model.py`) returns False for any `attn_type == "hybrid"` model — "Hybrid models do not
   support prefix caching since the feature is still experimental" — and Qwen3.8-27B is `qwen3_5`,
   i.e. hybrid. Correctness passed, but that is one afternoon; run it a while before flipping the
   default. That same line, at `logger.debug`, is why the feature being off was never explained —
   `VLLM_LOGGING_LEVEL=DEBUG` shows it.

Not worth chasing: QuickReduce (arch-gated, never RDNA4); PP=2 instead of TP=2 (batch-1 decode
serialises both shards, ~21 tok/s, worse); TP=1 (29 GB of weights + KV will not fit 30.4 GB
usable); PCIe tuning (already 5.0 x16); the one-shot Triton JIT warnings (not steady state).
Higher ceiling but invasive: this image already patches `_ON_MI3XX` in rocm.py to include gfx1201,
so patching `use_custom_allreduce()` the same way may light up the one-shot custom all-reduce —
generic HIP, but needs correctness checking (garbage output / hangs), and pairs with `iommu=pt`
(`rpm-ostree kargs --append=iommu=pt`, reboot; no IOMMU kargs are set today). NOTE: someone
already did this — stilldeadcode/vllm-radiance ships it as RADIANCE_FAST_REDUCE, so the cheap
way to evaluate the idea is to run that image rather than to patch this one. See the
gfx1201-patched-images note under DEAD ENDS above; the 11% ceiling still applies either way.

Qwen3.8-27B is vision-capable; the launcher serves it text-only (--language-model-only) to save
VRAM. To enable vision, drop that flag in the launcher copy (costs VRAM).

Context: this is a HYBRID model (qwen3_5) — 48 of 64 layers are linear-attention (constant state),
only 16 are full-attention, so the growing KV cache is a QUARTER of a classic 27B. Measured on the
pair: 0.033 GiB per 1K tokens per rank, ~0.066 GiB/1K across both. Native max is 262144 (256K);
the default seeds 131072. To go to the full 256K, set it in a shadowed unit:

    Environment=VLLM_MAX_MODEL_LEN=262144      # 256K native, no rope-scaling needed

**256K does not cost VRAM — it costs concurrency.** Per-card usage barely moves (~28.1 → ~28.4 GiB)
because `gpu_memory_utilization=0.95` is a *budget*, not a demand: the KV pool is whatever fits in
it either way. Raising the limit just lets one request consume more of that fixed pool. Measured:

    128K   KV pool 314,572 tokens   max concurrency 2.40x
    256K   KV pool 332,781 tokens   max concurrency 1.27x

So there is no memory reason to stay at 128K, only a batching one. Note a full 256K prompt is also
several minutes of prefill, which is the better argument for the 128K default.

No fp8 KV-quant needed at these sizes; add `--kv-cache-dtype fp8` in the launcher only if you also
want vision or many concurrent sequences. (The model ships an MTP draft head and the launcher uses
it by default — see `VLLM_SPECULATIVE` above.)

## VRAM / OOM

`torch.OutOfMemoryError: CUDA out of memory` in the journal is a **VRAM** OOM, not host RAM (the
box has 59 GB and has never kernel-OOM'd). Confirm which:

    journalctl --user -u vllm -o short-iso | grep -E 'OutOfMemoryError|Tried to allocate'
    for c in /sys/class/drm/card1 /sys/class/drm/card2; do \
        awk '{printf "%.2f GiB\n", $1/1073741824}' $c/device/mem_info_vram_used; done

**64 GB is not one 64 GB pool.** TP=2 shards weights, KV and activations across the pair; it never
aggregates them. The binding constraint is always ONE card's 31.86 GiB, and the ~4.1 GiB of
non-torch overhead (HIP context, RCCL, hipBLASLt/triton workspaces) is paid PER RANK, not shared.

Per-card ledger, from the startup log (`Model loading took`, `Available KV cache memory`,
`Graph capturing finished`), measured 2026-08-24 at the current 0.80 / 8192 defaults:

    weights + MTP head   14.68 GiB
    KV cache              7.87 GiB   (225,652 tokens = 1.72x the 128K context)
    CUDA graph capture    0.81 GiB
    non-torch            ~1.0  GiB cold, grows to ~4.1 GiB in use (duplicated per rank)
    ------------------------------
    idle                 24.41 GiB of 31.86  ->  ~7.4 GiB/card free (~14.9 GB across the pair)

WATCH THE NON-TORCH ROW. It is ~1 GiB at startup and settles around 4 GiB once real traffic has
loaded hipBLASLt/triton workspaces, and those are never released — measured idle climbing
28.5 -> 30.1 GiB/card over one afternoon at the old 0.95. It is NOT in vLLM's profiled budget, so
it eats the safety margin silently. This is the main reason not to run close to the limit.

The one OOM so far (2026-08-24) was a 16,146-token prompt prefilled in a single step under the
then-16384 token budget, dying on a 538 MiB GEMM output buffer with the KV cache only 8% used —
i.e. an ACTIVATION problem, not a context-length one. Fixed by 8192 + 0.80.

Sizing the KV cache: 36.6 KiB/token/card, so `KV_GiB ~= 31.86*util - 18.26`.

    util   KV GiB   KV tokens   x128K
    0.95    12.01     344,064    2.63
    0.90    10.42     298,428    2.28
    0.85     8.82     252,791    1.93
    0.80     7.23     207,155    1.58   <- current default (measured 7.87 / 225,652)
    0.75     5.64     161,518    1.23
    0.72     4.68     134,136    1.02   <- hard floor
    0.70     4.05     115,882    0.88   <- will NOT start

The floor is real: the KV cache must hold at least `max_model_len` (131,072) or vLLM refuses to
start. Below ~0.72 you must lower `VLLM_MAX_MODEL_LEN` too.

If an OOM happens again — all via `[Container] Environment=` in a shadowed unit (see "Switching
models" for the mechanism; a `[Service] Environment=` drop-in silently does nothing):

    Environment=VLLM_GPU_UTIL=0.75                               # per the table above
    Environment=PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True # untried; targets fragmentation
    Environment=VLLM_MAX_BATCHED_TOKENS=4096                     # halves the peak prefill step

Note that lowering `VLLM_MAX_BATCHED_TOKENS` alone does not simply free memory: vLLM profiles at
that size and gives whatever is left to the KV cache, so most of the saving reappears as KV.
`VLLM_GPU_UTIL` is the only knob that reserves headroom the KV cache cannot reclaim.

Changing `VLLM_MAX_BATCHED_TOKENS` changes `compile_ranges_endpoints`, so the first start after
it misses the compile cache — expect ~80 s of `init engine` instead of ~12 s, once. Changing
`VLLM_GPU_UTIL` does not; it restarts in ~10 s.

## Concurrency: the MTP drafter crashes if disable_padded_drafter_batch is on

Symptom — several parallel requests all 500 at once, and the server exits (systemd restarts it):

    vllm/v1/spec_decode/llm_base_proposer.py:1082 in prepare_inputs
    assert common_attn_metadata.seq_lens_cpu_upper_bound is not None   -> AssertionError
    vllm.v1.engine.exceptions.EngineDeadError

Bisected on-box 2026-08-24 with four parallel 16K prompts: with the flag TRUE, n=2 is fine, n=3
and n=4 crash; with it removed, n=4 passed 12/12 across three rounds with zero assertions. It is
now removed from `SPEC_DEFAULT`, which costs the +19.1% decode measured on 2026-08-22 — that
benchmark was single-stream, which is why it never caught this.

To take the other side of that trade (keep the 19.1%, give up parallel tool calls):

    Environment='VLLM_SPECULATIVE={"method":"mtp","num_speculative_tokens":3,"disable_padded_drafter_batch":true}'
    Environment=VLLM_MAX_SEQS=2

Single quotes are load-bearing — systemd strips bare double quotes and vLLM then rejects the
mangled JSON with status=2/INVALIDARGUMENT. Do not run that flag at `VLLM_MAX_SEQS` above 2.

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

## Tool calling: strict mode is OFF while MTP is on

Symptom, if you ever see it again: Open WebUI web search (or any tool call) dies partway with
"Provider returned error (streaming) ... code 500", and the vLLM journal says

    backend_xgrammar.py:162 Failed to advance FSM for request ... for tokens 248069
    scheduler.py:1531 Unexpected: grammar rejected tokens [10429, 13, 198, 248069] ...

248069 is `</think>`, and the rejected batch is always 1+num_speculative_tokens long — that length
is the tell that speculation is involved, and it tracks k as you retune: this box's journal has
`[198, 248069]` (2 = k1) on 2026-08-19 and `[4757, 13, 198, 248069]` (4 = k3) from 08-20 onward.

NOT an Open WebUI problem — it is any client that sends `tools`, so a coding agent pointed at
:8000 (see "Coding / agent use" below) hits it just as hard. The 08-19 cluster was 16 failures in
45 minutes from a client hitting /v1/chat/completions directly while Open WebUI sat idle (its only
traffic that hour was version.json polls). If an agent is failing on "think grammar" or dying
mid-tool-call, look here first.

Reading those access logs: the source address is NOT a remote client. Both ports publish to
127.0.0.1 only, but pasta rewrites loopback-forwarded connections to the host's own LAN address,
so on-box traffic shows up as 192.168.0.152 — this box. Don't chase it as an intrusion or assume
the API is LAN-exposed; `ss -ltn` is the honest answer for what is reachable.

Open WebUI defaults to NATIVE function calling, so an
ordinary chat carries `tools`; VLLM_ENFORCE_STRICT_TOOL_CALLING defaults True in this image, which
attaches an xgrammar structural tag to constrain tool-call syntax. Structured output is meant to
stay out of the thinking block — should_advance() defers the FSM by one step at the `</think>`
boundary — but that deferral has an escape hatch for speculative decoding + structural tags that
advances anyway, so with MTP on the grammar is fed the reasoning text and the closing tag and
rejects them. Upstream vllm-project/vllm#44006, fixed by #44297 on 2026-07-04; this image is the
2026-06-13 build, three weeks short of it. Only the `tools` path is affected —
response_format/json_schema and plain chat take the ordinary deferral and measured clean.

The launcher therefore exports VLLM_ENFORCE_STRICT_TOOL_CALLING=0 whenever speculation is on. No
grammar is attached, so the boundary is never reached; tool calls fall back to the qwen3_coder
parser's extract_tool_calls, which is how vLLM did tool calling before strict mode existed.
Measured on-box 2026-08-23: 3/12 requests failed before, 0/16 after, with MTP still at k=3 and
tool calls still parsing to well-formed JSON arguments.

WHAT IT COSTS: tool-call syntax is no longer grammar-guaranteed, and `tool_choice="required"` or a
named function is no longer binding — with strict mode off the serving layer treats both as "auto"
(abstract_tool_parser.py `supports_required_and_named`), so a request that demands a tool call can
come back without one. Open WebUI only ever sends "auto", so its web search is unaffected; an agent
that relies on forced tool choice is not.

MEASURED 2026-08-24, thinking on, an unambiguous "what is the weather in Paris?" against a
get_weather tool, three runs each:

    tool_choice="auto"        3/3 returned get_weather({"city":"Paris"}), arguments parsed as JSON
    tool_choice="required"    1/3 returned a tool call; the other 2 returned NO tool call and
                              empty content — reasoning was produced, then nothing usable

So "required" is not merely downgraded to "auto", it is actively unreliable: the model is free to
answer without calling, and on a prompt this obvious it still failed two thirds of the time. Treat
forced tool choice as unavailable while strict mode is off, rather than as best-effort. A client
needing it must send "auto" and tolerate a missing call, or give up speculation.

Turning MTP off (VLLM_SPECULATIVE=) restores strict mode by itself, because without speculation
the deferral is correct.

WHEN TO UNDO THIS. An image with the fix already exists — kyuz0's `dev` and
`rocm7.14.0-torch2.11.0-vllm0.27.1` tags are a 2026-08-12 build of vLLM 0.27.1, comfortably past
the 2026-07-04 fix (the first release after it was 0.25.0 on 07-11). We are NOT on it on purpose:
0.27.1 is the build already measured ~15% slower at MTP decode (34.66 vs 40.75, see "Decode
performance"), so taking it trades throughput for a tool-calling guarantee this box barely uses.
Revisit when a build is both post-07-04 and not a decode regression.

Don't judge that from the tag name — the date-stamped tags stop at 20260613-143121 while the newer
builds hide under `dev`/version tags, so the tag list is not chronological:

    skopeo inspect docker://docker.io/kyuz0/vllm-therock-gfx1201:<tag> | grep -i created

And confirm the fix is actually in a candidate image rather than inferring from a version string —
#44297 added a `trim_reasoning_for_advance` helper, so it is present iff this prints something:

    podman run --rm --entrypoint "" docker.io/kyuz0/vllm-therock-gfx1201:<tag> \
        grep -rl trim_reasoning_for_advance /opt/venv/lib64/python3.12/site-packages/vllm

To undo: delete the `export VLLM_ENFORCE_STRICT_TOOL_CALLING` block from the launcher in
build_files/profiles/north/vllm.sh, rebuild, and remove any shadowed vllm.container that carries
the same Environment= line.

## Thinking / the reasoning field

Thinking is ON by default for Qwen3.8 and works with tools. The FSM bug above was what broke it;
since that workaround landed there have been zero recurrences. Verified 2026-08-24 across ~25
thinking-enabled requests with tools: 0 FSM failures, 0 500s, 0 restarts, tool arguments parsing
as JSON every time.

THE FIELD IS `reasoning`, NOT `reasoning_content`. This build puts reasoning in `message.reasoning`
(non-streaming) and `delta.reasoning` (streaming); `reasoning_content` — the older vLLM/DeepSeek
spelling most OpenAI-compatible clients implement — does not exist here and always reads empty.

    non-streaming  message.reasoning = "We need answer classic riddle. Need final concise..."
                   message.content   = "\n\nThe ball costs **$0.05**..."
    streaming      delta keys = ['content', 'reasoning', 'role', 'tool_calls']

If a client shows no thinking, or appears to "lose" output, check which spelling it expects before
concluding anything is wrong server-side. The symptom is easy to misread: `content` is clean and
correct, so the reply looks fine but truncated of its reasoning. A client reading the wrong field
sees nothing, and one that concatenates raw deltas sees reasoning inline in the answer.

Reading the wrong field also makes token accounting look alarming — `usage.completion_tokens`
counts reasoning, so comparing it against only the visible `content` suggests hundreds of tokens
are being discarded when nothing is.

How the template drives it (`tokenizer_config.json`, chat_template):

    enable_thinking=false  ->  prompt ends '<think>\n\n</think>\n\n'   (empty, pre-closed block)
    otherwise              ->  prompt ends '<think>\n'                 (model starts INSIDE it)

So with thinking on the OPENING tag is in the prompt and only `</think>` appears in the output —
which is why a reasoning parser that requires a start tag would fail. The `qwen3` parser handles
both styles.

### Reasoning effort is pinned to `medium` here

The template's other kwarg is `reasoning_effort`, `'xhigh' | 'medium' | 'low'` — it resolves
`reasoning_effort|default('xhigh')`, so leaving it unset selects the HIGHEST level, not a neutral
one. (`'high'` is accepted and aliased onto `'xhigh'`.) Since 2026-08-25 the launcher pins it:

    --default-chat-template-kwargs '{"reasoning_effort":"medium"}'

WHY, and it is not only about answer style. At xhigh the model will spend most of a small
max_tokens budget inside `<think>` and return little or no content — that reads as a bug and is
not one. The bigger cost is that reasoning tokens stay in the context and are re-read on every
later forward pass: against the context model in "Decode performance"
(`ms/pass = 1.186*ctxK + 47.2`), context is 64% of the forward pass at the ~70K an agentic loop
actually runs at. Thinking is paid for once when it is generated and again by every turn after it.

UNMEASURED on this box. `medium` is the conservative middle, not a benchmarked optimum, and no
quality A/B has been run — treat it as a default someone chose, not one someone proved. The decode
numbers elsewhere in this file are unaffected either way: they are all measured with
`enable_thinking: false`.

To change it, either ask per request — request-level `chat_template_kwargs` OVERRIDE the server
default, which is also why `bench.py` and `ksweep.py` still get thinking off:

    {"chat_template_kwargs": {"reasoning_effort": "xhigh"}}

or move the server default in a shadowed unit (see "Switching models"):

    Environment=VLLM_REASONING_EFFORT=xhigh     # xhigh|high|medium|low
    Environment=VLLM_REASONING_EFFORT=          # empty: don't pass the flag, model default (xhigh)

The launcher GUARDS the flag rather than trusting it, because the unit is `Restart=always` and
vLLM exits 2/INVALIDARGUMENT on an unrecognised argument — a bad flag here is a restart loop, not
a message. It greps the installed vLLM for the option and, if it is missing, starts WITHOUT it and
says so in the journal:

    [vllm-serve] WARNING: this image's vLLM has no --default-chat-template-kwargs

If you see that line, the box is running at xhigh regardless of the knob. There was also an
upstream window where the flag parsed but was silently ignored ("[Frontend][Bugfix] respect
server-level default chat template kwargs", merged 2026-01-05); this 2026-06-13 build is past it,
but that is the thing to re-check after an image bump, and greppability does not prove it. Confirm
the effort actually moved by watching `usage.completion_tokens` on a fixed prompt, not by reading
the flag back out of `ps`.

## Coding / agent use

Point your agent (opencode, aider, Continue, ...) at:

    base URL   http://127.0.0.1:8000/v1      (any api key; ignored)
    model      Qwen/Qwen3.8-27B-FP8   (or whatever VLLM_MODEL is set to)

The default has tool-calling (--enable-auto-tool-choice, qwen3_coder parser) enabled.

## Relationship to lemonade

Separate stack, separate ports (lemonade is :13305). They only share the model store above.
Run whichever you want; running both at once contends for VRAM, so stop one first.

Neither is "the fast one". Head to head on this pair, same day, batch 1:

    vLLM FP8       27.8 GB weights, MTP k=3   54.22 tok/s
    llama.cpp      14.0 GB IQ4_XS,   MTP      56.86 tok/s

llama.cpp reads half the bytes per token and wins by only ~5% — its quantisation advantage is
almost entirely cancelled out by vLLM being the more efficient engine. Pick on features (batching,
tool-calling, OpenAI API) rather than on speed.

## Surviving logout

Already handled — `kinoite-linger.service` runs `loginctl enable-linger` for every regular
account at boot, so a hand-started server outlives the session that started it. That matters
here more than it looks: start vLLM over SSH without linger and the engine dies the moment
that SSH session ends, mid-request, with nothing in the log to explain it.

It cannot be baked as a file — linger is recorded under /var/lib/systemd/linger and /var is
machine-local state, not image content — so it is re-asserted each boot. Confirm with
`loginctl show-user $USER -p Linger`. To opt out, mask the service AND disable-linger; the
second alone is undone at the next boot. Linger starts no LLM by itself: the Quadlets have
no [Install] section.

## Suspend / resume

Handled automatically by `kinoite-llm-sleep.service`. Not a power tweak — **with a model loaded
and this hook off, suspending hangs the machine.** amdgpu evicts VRAM into system RAM to suspend;
vLLM holds ~28 GiB on each R9700 against 64 GB of RAM, and it does not fit. The kernel stops after
`PM: suspend entry` / `Filesystems sync`, never reaches `Freezing user space processes`, and logs
no error at all — fans on, no video, no network, recoverable only by holding the power button.

    before sleep   stops north-llm-pod + vllm + open-webui + lemonade (whichever are up),
                   recording what was running to /run/kinoite-llm-sleep/<uid>
    after resume   starts back exactly those units, with --no-block

It **restores state, it does not enforce policy**: stop vLLM by hand before suspending and it
stays stopped after you wake, so waking the box to stream a game leaves both dGPUs free. Restore
goes through the MEMBER units, never the pod. `/run` is tmpfs on purpose — after a cold boot
nothing starts, matching the missing `[Install]` sections.

Expect **1-2 minutes** before the API answers again; the weights reload even though the
torch.compile cache survives. `journalctl --user -u vllm -f` and wait for `Application startup
complete` — because the restore is `--no-block`, the hook's own journal only proves the start job
was accepted, not that the server came up.

One hook covers suspend, hibernate and hybrid-sleep (all four sleep services `Requires=sleep.target`).

Both edges can be tested **without suspending the box** — call the helper, not the unit:

    systemctl --user start vllm                    # wait for Application startup complete
    sudo /usr/libexec/kinoite-llm-sleep pre
    cat /run/kinoite-llm-sleep/$UID                # vllm.service / open-webui.service
    grep . /sys/class/drm/card*/device/mem_info_vram_used   # ~28 GiB -> ~57 MiB in a few seconds
    sudo /usr/libexec/kinoite-llm-sleep post

`systemctl start kinoite-llm-sleep` is *not* the first half of that: `StopWhenUnneeded=yes` makes
a manual start immediately unneeded, so both edges fire ~40 ms apart. Only manual starts behave
that way — during a real sleep cycle sleep.target holds the unit until resume, which is exactly
what drives the restore. `journalctl -u kinoite-llm-sleep -b` shows both edges either way;
interleaved `pam_unix(runuser:session)` lines are the transport, not a problem.

To opt out: `systemctl disable kinoite-llm-sleep.service` — **disable, not mask.** The unit is
`RequiredBy=sleep.target`, so masking leaves sleep.target requiring a masked unit and the box
cannot suspend at all. Once it is off, stop the LLM stack yourself before suspending. It also
depends on `kinoite-linger.service` for the user bus it talks to, so masking linger disables this
too.

EOF
