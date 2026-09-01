# kinoite-north: vLLM + Open WebUI (rootless Quadlet pod)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`) are
> here in `/usr/share/kinoite/`.

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

Qwen/Qwen3.8-27B-FP8, TP=2, batch 1. Current shipped defaults:

    no MTP                                  24.3 tok/s
    MTP k=4 (what ships)                    55.9 tok/s

Full sweeps and the batch >1 arms are in
docs/runs/2026-08-22-vllm-speculation-sweep.md.

`disable_padded_drafter_batch` is NOT set, and must not be re-added: it is
+19.1% single-stream and crashes the engine at n>=3 concurrent requests. See
docs/decisions/2026-08-24-drop-padded-drafter-batch.md.

Decode falls off hard with prompt depth once speculation is on. Budget with:

    ms/forward_pass = 1.186 * (context in K tokens) + 47.2      valid 40-130K
    tok/s = 1000 * acceptance_length / ms_per_pass              acceptance 2.5-2.8

    ctx     ms/pass   tok/s @ acc 2.8
      20K      71          39
      40K      95          30
      70K     130          22
     128K     199          14

At 70K the context term is 64% of the forward pass, so **context management
beats every tuning knob here** — holding a working context at 20K instead of 70K
is ~1.8x decode for free. Fit and validation in
docs/runs/2026-08-25-vllm-context-and-clocks.md.

Two things that look like problems and are not, both settled by measurement:

- `THROTTLE_STATUS: THROTTLED` with sclk ~2360 MHz against a ~3360 MHz ceiling.
  Cooling the cards raises sclk 43% and changes ms/pass by 0.4%. Batch-1 decode
  is memory-bandwidth bound; `mclk` is at top DPM throughout. Do not raise the
  power cap hoping for tok/s.
- A slow-looking in-flight request. Generation slows as context grows, so a
  running request at 58K is not comparable to a fresh-load short-prompt figure.
  Compare at equal depth or fit the model above.

Where the 41 ms non-speculative budget goes, why 4-bit is weaker than it looks
for this model, the eliminated dead ends, and the upstream TP=2 hang this box
does not have: docs/explanation/vllm-decode-budget.md.

Prefix caching is ON by default since 2026-08-31 (knob 5 below to change it).
Nothing ever disabled it before that — it was never enabled, because the model is
hybrid and upstream gates the feature as experimental, logged at
`logger.debug`. See docs/decisions/2026-08-31-vllm-prefix-caching-on.md.

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
5. `VLLM_PREFIX_CACHING` — **ON by default since 2026-08-31** (was opt-in). Set it to `false` to
   disable. For agentic coding, where every request repeats a big fixed prefix. Measured
   2026-08-22 (~6K-token shared prefix, six questions): TTFT goes from a flat 3.33 s per request
   to 3.47 s once, then **0.47 s — 7.4x** on every request after. Decode unchanged; stacks with
   the drafter flag. The launcher adds the required `--mamba-cache-mode align` automatically.

   The default flipped once the multi-turn agentic arm measured the whole request rather than
   TTFT alone: warm-prefix TTFT **5.573 s -> 0.441 s**, wall per turn **10.329 s -> 5.805 s**,
   end-to-end **24.09 -> 41.63 tok/s (1.73x)**. Without it TTFT climbs monotonically with turn
   number as each turn re-prefills a growing conversation. Decode is unaffected: ms/pass flat
   within ±0.6% at every depth. See docs/decisions/2026-08-31-vllm-prefix-caching-on.md.

   It still overrides an upstream gate, and that is unchanged by the throughput result:
   `is_prefix_caching_supported` (`config/model.py`) returns False for any `attn_type == "hybrid"`
   model — "Hybrid models do not support prefix caching since the feature is still experimental" —
   and Qwen3.8-27B is `qwen3_5`, i.e. hybrid. Correctness spot-checks passed on 08-22; no quality
   A/B has ever been run. **If output quality is ever suspect, `VLLM_PREFIX_CACHING=false` is the
   first thing to try.** That same gate line, at `logger.debug`, is why the feature being off was
   never explained — `VLLM_LOGGING_LEVEL=DEBUG` shows it.

Not worth chasing: QuickReduce (arch-gated, never RDNA4); PP=2 instead of TP=2 (batch-1 decode
serialises both shards, ~21 tok/s, worse); TP=1 (29 GB of weights + KV will not fit 30.4 GB
usable); PCIe tuning (already 5.0 x16); the one-shot Triton JIT warnings (not steady state).
Higher ceiling but invasive: this image already patches `_ON_MI3XX` in rocm.py to include gfx1201,
so patching `use_custom_allreduce()` the same way may light up the one-shot custom all-reduce —
generic HIP, but needs correctness checking (garbage output / hangs), and pairs with `iommu=pt`
(`rpm-ostree kargs --append=iommu=pt`, reboot; no IOMMU kargs are set today). NOTE: someone
already did this — stilldeadcode/vllm-radiance ships it as `RADIANCE_USE_R4D_AR` (the
`ar_oneshot_2rank_exact` kernel from libr4d), so the cheap way to evaluate the idea is to run
that image rather than to patch this one. The 11% comm ceiling still applies either way — see
docs/runs/2026-08-30-p2p-bandwidth.md.

P2P IS AVAILABLE AND IT IS ONLY PCIe. Peer access is enabled between every pair, but a copy
between the two R9700s runs at the same speed as a copy to host memory — there is no fast direct
link, so P2P just removes a host bounce. A working one-shot all-reduce is therefore not vacuous
and also not a step change: the 11% comm share is the ceiling on all of it. Matrices, NUMA
distances and the iGPU figure: docs/runs/2026-08-30-p2p-bandwidth.md.

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

## KV cache grouping: the padding warning is normal, and this split is already optimal

The startup log says:

    WARNING kv_cache_utils.py:1174 Add 3 padding layers, may waste at most 6.25% KV cache memory

Not an error, and not fixable here. vLLM slices layers into equal-size groups for KV management,
and any bucket that does not divide evenly is padded with placeholder layers that still get
allocated real memory. Group size is the SMALLEST bucket (upstream picks `min` over the buckets —
the FIXME in kv_cache_utils.py acknowledges it is the wrong strategy for complex patterns).

This box's buckets: 48 gated-delta-net (linear attention) + 17 full attention (16 from the model
+ the 1-layer MTP head, which merges into the full-attention bucket). min = 17, so 48 pads to 51:
4 groups x 17 = 68 slots for 65 real layers, 3 padding. 3/48 = 6.25%, exactly the warning. Group
size 17 is provably optimal under the only constraint that matters (never more groups than today):
18 -> 7 wasted, 24 -> 7, 48 -> 31; zero waste would need a size dividing both 48 and 17, and
gcd(48,17) = 1, i.e. 65 groups. Even a perfect patch is worth at most the 3 padding slots —
~4% of the pool (~10K of the ~225K tokens at 0.80).

THE TRAP is a multi-layer drafter, which forms a third bucket. A 5-layer DFlash2-style drafter
against 48+16 gives buckets 48/16/5, min = 5, 48 -> 50 and 16 -> 20: 15 groups x 5 = 75 slots
for 69 layers, 8% wasted before counting 15 per-request round-ups. An upstream patch that
searches for the least-wasteful group size instead of `min` (their buckets -> size 8, 9 groups,
72 slots) reportedly reclaimed ~21% of KV on that pairing (evaluated against this repo 2026-08-27;
their pads sat in expensive full-attention slots, which is why it beats the naive 4.2% block-count
estimate). None of it applies here: the 1-layer MTP head is what keeps this box in the good case —
a drafter with 4 or 8 layers would waste nothing either. If you ever swap MTP for a multi-layer
drafter, re-read that warning line before believing the pool numbers.

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

**THE IMAGE-BUMP RULE IS THREE CONDITIONS, not two.** A candidate must be (1) post-07-04, so it
carries the fix, (2) not a decode regression, and (3) must not reintroduce the TP=2 hang. The
third one exists because RCCL moves as a side effect of an image bump — why, and the RCCL
versions each image ships: docs/explanation/vllm-decode-budget.md.

Don't judge any of that from the tag name. The date-stamped tags stop at 20260613-143121 while
the newer build hides under `dev`/version tags, so the tag list is not chronological — and two
tag names are not two builds. Re-checked 2026-08-30: `dev`, `rocm7.14.0-torch2.11.0-vllm0.27.1`
and `sha-c5dd87e` are ONE image, digest `sha256:f36940bd…`, created 2026-08-12T18:56:46Z. Every
other `sha-*` tag predates `:latest` (`sha256:55fa7796…`, 2026-06-13T14:54:38Z). Compare digests:

    skopeo inspect docker://docker.io/kyuz0/vllm-therock-gfx1201:<tag> | grep -iE 'created|Digest'

And confirm the fix is actually in a candidate image rather than inferring from a version string —
#44297 added a `trim_reasoning_for_advance` helper, so it is present iff this prints something:

    podman run --rm --entrypoint "" docker.io/kyuz0/vllm-therock-gfx1201:<tag> \
        grep -rl trim_reasoning_for_advance /opt/venv/lib64/python3.12/site-packages/vllm

Verified 2026-08-30: absent in `:latest`, present in the 0.27.1 image (`v1/core/sched/scheduler.py`
and `v1/structured_output/__init__.py`). Check the RCCL version in the same pass — it is the
thing condition (3) is about:

    podman run --rm --entrypoint "" docker.io/kyuz0/vllm-therock-gfx1201:<tag> \
        bash -c 'strings $(find / -name librccl.so.1 2>/dev/null | head -1) | grep -m1 "RCCL version"'

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
one. Those three are the WHOLE set — `'high'` is not a level, and the template raises on it:

    {"enable_thinking":true,"reasoning_effort":"high"}
    -> 400 Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low.

Nothing validates the value at startup, so passing `high` here yields a server that comes up clean
and then 400s every chat request; the launcher's case statement is the only thing that catches it.
Since 2026-08-25 the launcher pins it:

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

    Environment=VLLM_REASONING_EFFORT=xhigh     # xhigh|medium|low
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

Separate stack, separate ports (lemonade is :13305). They only share the model
store above. They cannot run at once — lemonade Q8XL holds ~22 GB/card and vLLM
FP8 needs ~28 GB of 32 GB — so stop one before starting the other.

**llama.cpp is the decode path on this box.** vLLM wins warm-prefix TTFT (2.2x)
and 4-way short-prompt concurrency; llama.cpp wins decode at every depth and
end-to-end agentic throughput by 1.16x at current defaults. Pick vLLM for the
OpenAI surface and prefill, not for throughput at agentic context depth.

The full comparison, both engines' measured tables and the tool-calling
differences: docs/explanation/engine-choice.md.

One footnote worth keeping here, because it looks like a contradiction and is
not. The context model above (`1.186*ctxK + 47.2`) was fitted at k=3; the box
now ships k=4, whose fit is steeper (1.501) with a higher intercept (60.98). At
70K the old model predicts 130.2 ms/pass which, at the acceptance it assumed
(2.8), is 21.5 tok/s — and measured throughput at 70K is 21.31 tok/s. Acceptance
rose (2.8 -> 3.52, +26%) and per-pass cost rose with it (+27%), and they cancel.
The old model still predicts throughput correctly; just do not mix its ms/pass
with a k=4 table's.

## Getting a shell inside the pod

`podman exec` into these containers FAILS under `runuser` — `OCI permission
denied` writing the payload cgroup, because there is no session cgroup
delegation. From a service context or a runuser shell, use:

    nsenter -t $(podman inspect north-llm-infra --format '{{.State.Pid}}') -n

From a real login session `podman exec` works normally.

Cosmetic, ignore: `Unknown vLLM environment variable detected: VLLM_MODEL`. The
launcher's own knobs collide with vLLM's reserved `VLLM_*` namespace, and bash
reads them first.

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

