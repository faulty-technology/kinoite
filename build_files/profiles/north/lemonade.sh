#!/bin/bash
set -ouex pipefail

# Lemonade Server (local LLM) as a rootless Quadlet. No host ROCm — lemonade's
# llama.cpp builds bundle their own ROCm 7 runtime.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by
# hand with `systemctl --user start lemonade`. Runbook and gotchas are in
# /usr/share/kinoite/lemonade.md, written below.
#
# crun is still required: podman needs an OCI runtime and crun is what this image ships.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "lemonade.sh: missing $bin" >&2; exit 1; }
done

### 1. Seeded lemonade defaults
# nightly channel is CORRECTNESS, NOT PREFERENCE — do not "simplify" it to stable or preview.
# Cited, so the next person does not have to take it on trust: lemonade-sdk/lemonade#1787
# ("v10.3.0: ROCm preview/stable channels silently fall back to CPU on gfx1201 (RDNA4) — 7x
# performance regression vs v10.2.0", open since 2026-05-03). Neither `preview` (ROCm 7.12 /
# TheRock) nor `stable` (ROCm 7.2) contains HIP support for gfx1201; `llama-server --list-devices`
# prints an empty device list and the server then runs on CPU with NO error and NO warning —
# ~70 tok/s becomes ~10. Only `nightly` ships the per-arch builds
# (llama-bXXXX-ubuntu-rocm-gfx120X-x64.zip) that detect the R9700 at all. A silent 7x is the
# worst possible failure mode, which is why this is a pin and not a default.
# ctx_size because lemonade auto-tunes to 157140
# on a 27B — raise per-model if you have headroom. No rocm_args: `--load-mode mmap` was pinned
# throughout the SELinux bisect and carried forward untested. Isolated afterwards by loading a
# model without it under full confinement — ROCm loads fine, so it is gone. (lemonade passes its
# own `--no-mmap` to llama-server regardless, which is probably why it never mattered.)
mkdir -p /usr/share/kinoite
cat > /usr/share/kinoite/lemonade-defaults.json << 'EOF'
{
  "ctx_size": 131072,
  "rocm_channel": "nightly",
  "llamacpp": {
    "backend": "rocm"
  }
}
EOF

### 1b. Curated custom-model recipes (always-present superset)
# Baked to /usr/share/kinoite/lemonade-recipes and merged into the user's lemonade config
# on every start, per key (see kinoite-lemonade-seed and the ExecStartPre in the Quadlet).
# Names become user.<name> at runtime — run one with `lemonade run user.<name>`.
#
# This is a coding/testing box: Q6 quality floor AND big context — with ONE deliberate
# exception. `Qwen3.8-27B-Fast` is the same model at IQ4_XS (14.25 GB vs 21.98), kept
# alongside the Q6_K entry rather than replacing it, so the quality floor stays the
# default and speed is an explicit choice. Measured on the pair, 2026-08-20: IQ4_XS +
# MTP = 56.86 tok/s vs 30.40 without MTP, i.e. +87%.
#
# That +87% was measured on IQ4_XS ONLY. The Q6_K entry carries the same draft head, and
# the speculation multiplier should mostly carry over (acceptance is a property of the
# model and its draft head, not of how the main weights are quantised, and both arms scale
# with weight bytes) — but that is an EXTRAPOLATION, not a measurement. What does NOT carry
# over is the absolute number: Q6_K reads 21.98 GB per token against IQ4_XS's 14.25, so it
# starts from a lower baseline and lands lower. Rough expectation ~35 tok/s, unverified.
# Measure with the sweep in lemonade.md before quoting a figure for the Q6_K entry.
#
# What the Fast entry additionally buys is the ~1.6x fewer weight bytes per token, at
# 4.25 bpw across every tensor including the Gated DeltaNet layers that the vLLM-side
# 4-bit repacks refuse to touch. Judge the quality cost yourself before making it the
# default — it has NOT been quality-tested here, only benchmarked.
#
# These ctx_size values exceed one card, so they rely on the layer split across both
# R9700s — the AUTOMATIC default here (measured: a 27B put ~14 GB on each R9700 and
# nothing on the iGPU, no pinning). KV cost is ~0.25 GB/1K tokens for the dense 27Bs
# (64 layers, 4 KV heads, head_dim 256) and ~0.10 GB/1K for the MoEs — 27B Q6 at 128K =
# ~22 GB weights + ~33 GB KV = ~55 GB, ~28 GB per card. Whether 128K still fits the pair
# cleanly (and stays off the iGPU) at that size is an on-box check; fallback is lower ctx
# or q8_0 KV-quant. See lemonade.md.
#
# NOTE that 0.25 GB/1K is the DENSE estimate and is very likely wrong for Qwen3.8-27B,
# which is the hybrid qwen3_5 arch (48 of 64 layers linear-attention, constant state).
# vllm.sh works from ~0.0625 GB/1K for the same model — a quarter of the figure above.
# Nobody has reconciled the two on the llama.cpp side; if a 128K load is unexpectedly
# roomy, that is why. Do not size anything tightly against the 0.25 number.
#
# checkpoint pins the exact GGUF filename (all single-file here — no split parts). The two 27B
# dense models and the 35B MoE are vision-capable (mmproj-F16.gguf); the coder is text-only.
#
# EVERY model here that has an MTP head available now uses it. unsloth ships MTP in TWO
# different packagings, and which one a model uses decides how the recipe is written:
#
#   1. SEPARATE draft file, in the same repo — Qwen3.8-27B, at
#      unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf (1.37 GB).
#      Needs the `checkpoints` OBJECT form with a `draft` key. In that form mmproj moves
#      INSIDE the object and every value is fully qualified `repo:file` — the bare-filename
#      mmproj only works alongside the scalar `checkpoint` key.
#
#   2. EMBEDDED in the main GGUF, in a SEPARATE sibling repo — Qwen3.6-27B and
#      Qwen3.6-35B-A3B, via unsloth/<model>-MTP-GGUF. There is no mtp-*.gguf in those
#      repos at all; the head is inside the weights, which is why the same quant is
#      slightly larger there (Qwen3.6-27B Q4_K_XL: 18.5 GB plain vs 18.8 GB MTP).
#      Stays the scalar `checkpoint` form — just repoint the repo. The Q6_K FILENAMES are
#      identical in both repos, so this is a pure repo swap, not a requant.
#
# Both are verified on-box 2026-08-20 by loading a model of each kind and grepping the
# resulting llama-server command line: form 1 via Gemma-4-12B-it-MTP-GGUF, form 2 via
# Qwen3.5-4B-MTP-GGUF. In BOTH cases lemonade adds `--spec-type draft-mtp
# --spec-draft-n-max 3` by itself; form 2 additionally passes no `-md`, because llama.cpp
# reads the head out of the main file. Nothing here has to pass the flags manually.
#
# Qwen3-Coder-30B is the one model with no MTP option — neither
# unsloth/Qwen3-Coder-30B-A3B-Instruct-MTP-GGUF nor -Coder-30B-MTP-GGUF exists (both 404
# via a 401 from the HF API), and the base repo has no mtp file. Recheck on a model bump.
#
# See "Performance notes" in lemonade.md for the measured table.
#
# The main filename is `Qwen3.8-27B-UD-Q6_K.gguf`, with the UD- prefix. There is no plain
# `Qwen3.8-27B-Q6_K.gguf` in that repo — an earlier revision of this file pinned that name and it
# would have failed on first pull. Check names against
# `curl -s https://huggingface.co/api/models/<repo> | python3 -c 'import json,sys;
# [print(f["rfilename"]) for f in json.load(sys.stdin)["siblings"]]'` before editing a pin.
command -v python3 >/dev/null || { echo "lemonade.sh: missing python3 (JSON validation)" >&2; exit 1; }

mkdir -p /usr/share/kinoite/lemonade-recipes
cat > /usr/share/kinoite/lemonade-recipes/user_models.json << 'EOF'
{
  "Qwen3.8-27B": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q6_K.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 23.4,
    "labels": ["vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.8-27B-Fast": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-IQ4_XS.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 15.6,
    "labels": ["vision", "reasoning", "coding", "mtp", "fast"]
  },
  "Qwen3.8-27B-Q6XL": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q6_K_XL.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 25.3,
    "labels": ["vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.8-27B-Q8XL": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q8_K_XL.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 31.5,
    "labels": ["vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.6-27B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 22.9,
    "labels": ["vision", "reasoning", "mtp"]
  },
  "Qwen3.6-35B-A3B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 30.0,
    "labels": ["vision", "reasoning", "mtp"]
  },
  "Qwen3-Coder-30B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf",
    "recipe": "llamacpp",
    "size": 25.1,
    "labels": ["coding"]
  }
}
EOF

# Per-model ctx, keyed by the fully-qualified user.<name> id. Sized for the automatic
# two-card layer split (64 GB pool): 128K on the dense 27Bs and 35B, native 256K on the
# coder. On a single card these OOM — drop ctx or add q8_0 KV-quant. At 128K the KV is
# large; if it won't fit the pair or spills to the iGPU, see lemonade.md. backend inherits
# rocm from defaults.json.
#
# `-sm tensor` IS BAKED, on the two heavy-quant seeds only (`-Q6XL`, `-Q8XL` above), as of
# 2026-08-30. Everything below is the evidence that got it there, kept because a reviewer needs
# it and because the three seeds that do NOT carry it are held back for a specific reason, not
# an inherited one.
#
# READ THE HISTORY OF THIS BLOCK WITH CARE. Earlier versions of it said "NO -sm tensor HERE" and
# read as standing policy. That was never a reviewed decision — it was a running note written
# while device selection was still unsolved, and each of the reasons it gave has since been
# measured away (reason 1, reason 2, and (a)/(e) below). It should not be cited as a reason to
# leave tensor split alone; the numbers below are the reason it is now on.
#
# The performance question is answered, and it answered in tensor split's favour: measured on the box that day against the 27B (Qwen3.8-27B-UD-IQ4_XS, ctx 32768, fresh
# load per arm, full table in lemonade.md "Tensor parallelism"),
#
#     -sm layer  + MTP   56.61 tok/s     cards 9099 / 11739 MiB
#     -sm tensor + MTP   81.75 tok/s     cards 10353 / 10353 MiB      +44.4%
#
# and the two levers COMPOSE — `--spec-type draft-mtp` keeps the same acceptance (0.464, mean
# accepted length 2.85) under tensor split, so this is not a trade against MTP's +87%, it is on
# top of it: 2.69x the unspeculated layer-split baseline. It is also a FLOOR, because this build
# has no RCCL and every tensor run falls back to ggml's butterfly reduction (see lemonade.md).
# The 4B result that used to sit here (106.69 vs 105.59, "noise") was measuring a model small
# enough that layer split costs nothing; it was not evidence about the 27B and has been retired.
#
# THE CASE GOT STRONGER ON A HEAVY QUANT, which is the argument that matters for the Q6_K seeds
# above rather than for the IQ4_XS `-Fast` one. Re-run 2026-08-30 on Qwen3.8-27B-UD-Q8_K_XL
# (31.5 GB), same MTP head, four prompt depths (full table in vllm.md):
#
#     -sm layer  + MTP   51.96 tok/s short, 34.05 at 70K   -> 0.82x vLLM short, 1.60x at 70K
#     -sm tensor + MTP   77.39 tok/s short, 55.67 at 70K   -> 1.22x vLLM short, 2.61x at 70K
#
# At 4 bpw layer split beats vLLM at every depth, so nothing forces the issue. At 8 bpw it does
# not: layer split LOSES to vLLM below ~11K context, and only `-sm tensor` wins everywhere. So
# the heavier the seed's quant, the more tensor split stops being an optimisation and starts
# being what keeps this stack ahead at all.
#
# AND THE SEEDS' OWN QUANT WAS MEASURED THE SAME EVENING, so this is no longer an extrapolation
# from Q8. Qwen3.8-27B-UD-Q6_K_XL (25.3 GB), same MTP head, same four depths:
#
#     -sm layer  + MTP   54.16 tok/s short, 34.20 at 70K   -> 0.86x vLLM short, 1.60x at 70K
#     -sm tensor + MTP   80.19 tok/s short, 54.31 at 70K   -> 1.27x vLLM short, 2.55x at 70K
#
# The crossover moved down from Q8's ~11K to roughly 6-7K but did NOT disappear: layer split
# still loses to vLLM on short prompts, which is exactly what an agentic loop's opening turns
# look like. Two further readings, both in notes/kinoite-north-validation.md: Q6 decodes the
# same as Q8 to within noise (25.3 GB and 31.5 GB of weights are indistinguishable here, only
# ~IQ4 is faster), so a heavier seed costs almost nothing; and vLLM still wins 4-way SHORT
# concurrency while losing 4-way DEEP by 2.4x.
#
# THE TWO REASONS THIS USED TO CITE FOR HOLDING BACK ARE BOTH GONE. Kept in full because they
# are what a reviewer checks, and because reason 2's arithmetic is still load-bearing:
#
#   1. DEVICE SELECTION — SOLVED 2026-08-30, see "Device visibility" below. This file CAN
#      express it now: an ExecStartPre derives the GPU agents from KFD topology and writes
#      ROCR_VISIBLE_DEVICES into an EnvironmentFile the container reads, so the iGPU is out of
#      the picture before llama-server starts. That was the blocker; it no longer is.
#
#      It is also now measured that this is NOT optional and NOT a performance tweak. With the
#      previously deployed quadlet (no ROCR_VISIBLE_DEVICES), a tensor-split recipe FAILS THE
#      LOAD: `ROCm error: invalid kernel file / current device: 2` (the gfx1036 iGPU),
#      llama-server exit code 134, HTTP 500 from /api/v1/load. Same image, same mounts, same
#      recipe, plus ROCR_VISIBLE_DEVICES=0,1 -> loads clean. The recipe half and the device half
#      cannot ship independently.
#   2. `--fit` stops working (`llama_params_fit is not implemented for SPLIT_MODE_TENSOR`), so
#      every seeded ctx above stops being auto-sized against free VRAM and becomes a
#      hand-computed number. SOLVED 2026-08-30 for the Q6 seeds — the arithmetic exists now.
#      Two measured VRAM points on Q6_K_XL + MTP under tensor split (16535 MiB/card at
#      `-c 98304 -np 1`, 20896 MiB/card at `-c 196608 -np 4`) give 0.0444 MiB/token/card plus a
#      12174 MiB/card fixed term, hence:
#
#          ctx_size 131072 -> ~17.9 GB/card      ctx_size 262144 -> ~23.8 GB/card
#
#      Both fit a 32 GB card with wide margin. What remains is that these are CONSTANTS, not
#      auto-sized values: re-check them on a model or quant bump, because `--fit` will not.
#
# ---------------------------------------------------------------------------------------
# WHAT A BAKED TENSOR-SPLIT RECIPE WOULD REQUIRE.  Written 2026-08-30 so the next person is
# not blocked on a question this repo has already answered twice elsewhere.
# ALL OF (a)-(e) ARE NOW IMPLEMENTED. (b), (c) and (d) live under "Device visibility" further
# down this file, which is where the reasoning for their choices now sits; (a) and (e) are the
# `llamacpp_args` lines on the two `-XL` recipes above. Kept because the argument in (a)-(e) is
# what a reviewer needs in order to check the implementation.
# ---------------------------------------------------------------------------------------
#
# (a) The recipe half is one line, and passthrough is the ONLY route. lemonade emits no split
#     mode of its own: the `lemond` binary contains no `--split-mode` string at all (nor `-sm`,
#     `-devd`, `--spec-draft-device`, `--device-draft`, `-ngld`, `--gpu-layers-draft` — all zero
#     hits, re-verified 2026-08-30). So `-sm tensor` can only arrive two ways, and both are ours:
#
#         per recipe   "user.Qwen3.8-27B": { "ctx_size": <hand>, "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1" }
#         globally     config.json llamacpp.rocm_args  (note the LIVE box already carries
#                      "--load-mode mmap" there from before that seed was dropped — seeds are
#                      first-run only, so check what is actually in config.json before adding)
#
#     ONE ADDITION to that list, 2026-08-30 — the list above is correct but not exhaustive.
#     lemonade DOES have a device knob of its own: `llamacpp_device` / `--llamacpp-device`, in
#     its "Llama.cpp Backend Options" group next to `llamacpp_backend` and `llamacpp_args`, and
#     it sets `LLAMA_ARG_DEVICE` — llama.cpp's env form of `--device`. This does NOT change (b)
#     below, and if anything strengthens it: `--device` restricts the MAIN model only, so even
#     lemonade's own knob cannot cover the draft head, and visibility-level exclusion remains
#     the only single setting that covers every model the process opens. Worth knowing only so
#     nobody reaches for `--llamacpp-device` expecting it to solve the iGPU problem.
#
#     `-fa on` is MANDATORY, not decoration: without it llama.cpp refuses with
#     `SPLIT_MODE_TENSOR requires flash_attn to be enabled`.
#
#     ORDERING IS NOW MEASURED, 2026-08-30, by exactly the method this comment used to ask for:
#     set the key, load the model, read /proc/<pid>/cmdline of the launched llama-server. It
#     appends LAST and it MERGES PER FLAG rather than replacing. lemonade names the behaviour
#     itself in its log (`merge_args=true`). Three layers survive together:
#
#         architecture defaults   resources/architecture_defaults.json, key `qwen35`
#                                 (--temp/--top-p/--top-k/--min-p/--repeat-penalty and
#                                 --chat-template-kwargs '{"preserve_thinking":true}')
#         global backend args     config.json llamacpp.rocm_args  (--load-mode mmap)
#         per recipe              recipe_options.json llamacpp_args   <- appended last
#
#     So adding one flag does NOT wipe the qwen35 sampler block, and because passthrough lands
#     last it CAN override flags lemonade generates — which (e) depends on. `llamacpp_args` is
#     a documented recipe-option key, not a guess: architecture_defaults.json describes itself
#     as "recipe option key-value pairs ... overridden by model-level recipe_options" and its
#     values are llamacpp_args strings.
#
# (b) The device half is the actual blocker, and the obvious fix is the wrong one. Do NOT put
#     `-dev ROCm0,ROCm1` in llamacpp_args. It restricts only the MAIN model. Every MTP recipe
#     here also loads a DRAFT model, which has its own separate device list (`-devd` /
#     `--spec-draft-device`) defaulting to all devices — and lemonade cannot emit one (the string
#     is not in its binary; see (a)). Measured:
#     `-sm tensor -fa on -dev ROCm0,ROCm1` with `--spec-type draft-mtp` still aborts with
#     `invalid kernel file`, because the draft head landed on the iGPU. Adding `-devd
#     ROCm0,ROCm1` fixes it, but that is two flags that must stay in sync with each other and
#     with any future third model the process loads.
#
#     Exclude at VISIBILITY instead — one setting, process-wide, covers every model llama-server
#     opens. Verified on the box 2026-08-30, BOTH variables, each alone with NO `-dev` and NO
#     `-devd`: `HIP_VISIBLE_DEVICES=0,1` and `ROCR_VISIBLE_DEVICES=0,1` each run `-sm tensor` +
#     `--spec-type draft-mtp` clean, identical VRAM (10252 MiB per card) and identical acceptance.
#     That means an `Environment=` (or `EnvironmentFile=`) line on lemonade.container, NOT a flag
#     in the recipe.
#
#     Note the coupling this creates: llamacpp_args is per-recipe but device visibility is
#     per-container, so switching ONE recipe to tensor split pins devices for ALL of them. That
#     is harmless here — layer split already avoids the iGPU — but it is why the two halves
#     cannot be reviewed independently.
#
# (c) WHICH DERIVATION. The indices must be derived at runtime; notes/kinoite-north-validation.md
#     records DRM numbering reshuffling across kernels and boots, and hard-coding them is exactly
#     what this file refuses to do. This repo already has two derivations. Use the SECOND:
#
#       - llamafactory.sh asks torch for `gcnArchName` and keeps gfx1201. Right answer THERE,
#         wrong one here: it needs torch, and the consumer is torch itself so the index space is
#         guaranteed to match. The lemonade container has no torch, and the value has to be in
#         the container's ENVIRONMENT before llama-server starts — i.e. computed on the host,
#         before podman runs.
#       - lemonade.md's sysfs grep is the one that fits: pure /sys, no ROCm, no python, runs fine
#         from an ExecStartPre.
#
#             grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties
#
#         120001 = R9700 (gfx1201), 100306 = the iGPU (gfx1036). Node 0 is the CPU agent and is
#         not a GPU, so GPU-agent index = node index - 1; ROCR_VISIBLE_DEVICES indexes exactly
#         that agent list. Read on the box 2026-08-30: nodes 1,2 are gfx1201 at location_id
#         768/1536 (PCI 03:00.0 and 06:00.0) and node 3 is gfx1036 at 4096 (10:00.0), so the
#         answer today is `0,1`.
#
#         ONE CHECK BEFORE TRUSTING IT for HIP_VISIBLE_DEVICES rather than ROCR_VISIBLE_DEVICES:
#         HIP orders devices by PCI BDF, KFD orders them by topology node, and the two agree on
#         this box only because the nodes happen to be in ascending bus order. `location_id >> 8`
#         is the PCI bus, so sort the gfx1201 nodes by it and the two orderings cannot diverge.
#         ROCR_VISIBLE_DEVICES sidesteps the question entirely and is the safer pick.
#
# (d) MECHANISM. Quadlet cannot compute a value inline, so this is an ExecStartPre helper that
#     writes `ROCR_VISIBLE_DEVICES=<derived>` to a runtime file plus an `EnvironmentFile=` on
#     the [Container] section. There is already precedent for the shape: kinoite-lemonade-seed
#     is an ExecStartPre helper installed by this same script. Fail OPEN, not closed — if no
#     gfx1201 node is found, write nothing and let lemonade start on layer split, the way
#     llamafactory.sh warns rather than aborting when its filter comes up empty.
#
# (e) A SECOND FLAG IS REQUIRED, and without it the recipe route silently gives up 24%.
#     Measured 2026-08-30 on Qwen3.8-27B-UD-Q6_K_XL through an actual lemonade recipe. A recipe
#     carrying only `-sm tensor -fa on` reads 49.13 tok/s where the same model driven from the
#     CLI reads 65.53. That gap is NOT lemonade's proxy and NOT the harness: re-running raw
#     llama-server under the same measurement script gave 65.03 with the CLI flags and 49.72
#     with lemonade's, i.e. the shortfall reproduces outside lemonade entirely. Bisected one
#     flag at a time from the CLI baseline, everything lemonade adds is free EXCEPT one:
#
#         --load-mode mmap                                   64.81   none
#         the qwen35 sampler block                           64.43   none
#         --jinja --metrics --reasoning-format auto ...      64.56   none
#         --no-mmap                                          64.65   none
#         dropping -ngl 99 -ngld 99                          64.85   none
#         --spec-draft-n-max 3  (what lemonade sets)         66.99   slightly FASTER
#         --spec-draft-p-min 0.75  (what lemonade sets)      49.76   -24%   <-- the whole gap
#         --spec-draft-p-min 0.1                             64.65   none
#
#     THE TRAP: under p-min 0.75 acceptance goes UP (mean accepted length 3.01 vs 2.90) while
#     throughput goes DOWN. The gate makes the draft head bail out early, so each pass drafts
#     fewer tokens even though a higher fraction of them are accepted. Anyone tuning speculation
#     on this box by watching `mean len` alone will tune it backwards. Quote tok/s; treat
#     acceptance as diagnostic only.
#
#     With `--spec-draft-p-min 0.1` added, the recipe measures 66.97 tok/s at 16381 MiB/card —
#     at or slightly above the raw CLI. Adding `--spec-draft-n-max 4` on top changes nothing
#     (66.77), so lemonade's own n-max 3 is fine and only p-min needs overriding. NOT MEASURED:
#     whether p-min 0.75 is equally expensive under `-sm layer` (the layer arm showed a 12% gap
#     rather than 24%, hinting it is cheaper there, but it was not bisected), and whether 0.1
#     costs anything in output quality — no A/B has been run.
#
# WHERE IT IS ON, AND WHY IT IS NOT ON EVERYWHERE. All four `Qwen3.8-27B*` recipes carry
# `-sm tensor -fa on --spec-draft-p-min 0.1` at ctx 131072. They are one model in one arch
# (`qwen35`), which is the arch every table in this block was measured on, so the flag is
# applied exactly as far as the evidence reaches and no further. What backs each one:
#
#   - `-Q6XL` (UD-Q6_K_XL) and `-Q8XL` (UD-Q8_K_XL): MEASURED with these exact recipe lines —
#     67.30 and 60.69 tok/s, 18446 and 21368 MiB/card, four full-context slots, ~11 GB/card
#     spare.
#   - `-Fast` (UD-IQ4_XS): the split mode is measured on this very file (tensor 82.80 vs layer
#     55.96 control mean), and it is the smallest seed here, so VRAM is the least of the four —
#     the same arithmetic puts it near 13.3 GB/card at ctx 131072. What has NOT been run is this
#     recipe end to end through lemonade; the GGUF is not in the HF cache layout lemonade reads.
#   - `Qwen3.8-27B` (UD-Q6_K, 23.4 GB): INTERPOLATED, and the weakest of the four. It sits
#     between two directly measured quants (IQ4_XS 14.0 GB and Q6_K_XL 25.3 GB) on the same
#     model and arch, and is 1.9 GB smaller than Q6_K_XL, so expect a little under that seed's
#     18446 MiB/card. Not downloaded, so not run. If any of the four is going to surprise
#     someone, it is this one — but the surprise would have to survive being bracketed on both
#     sides by measured points.
#
#   - `Qwen3.6-27B`, `Qwen3.6-35B-A3B` and `Qwen3-Coder-30B` are DIFFERENT models and, for the
#     latter two, MoE. `-sm tensor` has an architecture gate (see below) whose failure mode is a
#     hard load failure, not a slow path, and upstream's exclusion list names MoE families. None
#     of the three is in the model cache, so none has been tested. DO NOT bake the flag on these
#     without loading them once first.
#
# The costs that remain, and that are worth re-reading before extending it further: `-sm tensor`
# forces the MTP draft sampler onto the CPU, turns that recipe's ctx into a hand-maintained
# constant (reason 2 above), and couples the recipe to container-level device pinning, because
# llamacpp_args is per-recipe while device visibility is per-container.
#
# By hand against the bundled binary, where nothing derives visibility for you, it is still:
#
#     HIP_VISIBLE_DEVICES=0,1 llama-server -m <gguf> -ngl 99 -c 32768 -sm tensor -fa on \
#         --spec-type draft-mtp -md <mtp.gguf> -ngld 99 --spec-draft-n-max 4
cat > /usr/share/kinoite/lemonade-recipes/recipe_options.json << 'EOF'
{
  "user.Qwen3.8-27B":      { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1" },
  "user.Qwen3.8-27B-Fast": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1" },
  "user.Qwen3.8-27B-Q6XL": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1" },
  "user.Qwen3.8-27B-Q8XL": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1" },
  "user.Qwen3.6-27B":     { "ctx_size": 131072 },
  "user.Qwen3.6-35B-A3B": { "ctx_size": 131072 },
  "user.Qwen3-Coder-30B": { "ctx_size": 262144 }
}
EOF

# Fail the build loudly on a JSON typo rather than shipping a config lemonade rejects.
for f in user_models recipe_options; do
    python3 -m json.tool "/usr/share/kinoite/lemonade-recipes/$f.json" >/dev/null
done

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
    command -v "$bin" >/dev/null || { echo "lemonade.sh: missing $bin" >&2; exit 1; }
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
### Recipe seeding
# Merges the image's seeds into the user's config PER KEY, and is why this is a script rather
# than the obvious `test -f <file> || install <file>`. That form is all-or-nothing per FILE:
# lemonade's Web UI writes user_models.json the first time anyone adds a custom model, and from
# then on every image seed is blocked forever — silently, because the conditional is doing
# exactly what it says. Observed on the box: one user-added model kept all five seeded recipes
# out of the model list indefinitely. Merging per key keeps user entries untouched and still
# delivers seeds the user has never seen. Never overwrites an existing key.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-seed << 'SEEDEOF'
#!/usr/bin/python3
"""Merge baked lemonade recipe seeds into the user's config, per key."""
import json
import os
import sys
import tempfile

PAIRS = (
    ("/usr/share/kinoite/lemonade-recipes/user_models.json", "user_models.json"),
    ("/usr/share/kinoite/lemonade-recipes/recipe_options.json", "recipe_options.json"),
)
dest_dir = os.path.join(os.path.expanduser("~"), ".local/share/lemonade/config")


def load(path):
    try:
        with open(path) as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else None
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as exc:
        print(f"kinoite-lemonade-seed: cannot read {path}: {exc}", file=sys.stderr)
        return None


os.makedirs(dest_dir, exist_ok=True)
for src, name in PAIRS:
    seeds = load(src)
    if not seeds:
        continue
    dest = os.path.join(dest_dir, name)
    cur = load(dest)
    # A corrupt or non-dict user file is left strictly alone: overwriting it would be the
    # data loss this whole approach exists to avoid.
    if cur is None:
        print(f"kinoite-lemonade-seed: leaving {name} untouched", file=sys.stderr)
        continue
    added = [k for k in seeds if k not in cur]
    if not added:
        continue
    merged = dict(cur)
    for k in added:
        merged[k] = seeds[k]
    try:
        fd, tmp = tempfile.mkstemp(dir=dest_dir, prefix=f".{name}.")
        with os.fdopen(fd, "w") as fh:
            json.dump(merged, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, dest)      # atomic; lemonade reads this file on every start
        os.chmod(dest, 0o644)
        print(f"kinoite-lemonade-seed: {name}: added {', '.join(added)}")
    except OSError as exc:
        print(f"kinoite-lemonade-seed: cannot write {name}: {exc}", file=sys.stderr)
SEEDEOF
python3 -c 'import ast,sys; ast.parse(open("/usr/libexec/kinoite-lemonade-seed").read())'

### Device visibility for the lemonade container
# WHY THIS EXISTS: the gfx120X-only llamacpp-rocm bundle has no kernels for the gfx1036 iGPU,
# and podman's `AddDevice=/dev/dri` hands the container every render node including it. Layer
# split survived that by accident — it simply assigned no layers to a device it could see —
# but anything that uses EVERY visible device dies on the first decode with
# `ROCm error: invalid kernel file`. That is `-sm tensor` today; it is also the reason the
# standing advice in lemonade.md was "if a load spills onto the iGPU, exclude it". Deriving the
# exclusion here turns that advisory into the default, so a load can no longer spill there.
#
# WHY VISIBILITY AND NOT A FLAG. `-dev` restricts only the MAIN model. Every MTP recipe also
# loads a DRAFT model with its own device list (`-devd`), and lemonade cannot emit one — the
# `lemond` binary contains no `-devd`/`--spec-draft-device` string at all (checked 2026-08-30).
# Measured that day: `-sm tensor -fa on -dev ROCm0,ROCm1` WITHOUT `-devd` still aborts, because
# the draft head went to all three devices. A visibility variable is one setting, process-wide,
# and covers every model llama-server opens now or later.
#
# WHY ROCR_VISIBLE_DEVICES AND NOT HIP_VISIBLE_DEVICES. Both were verified working on the box
# 2026-08-30 (identical VRAM, identical acceptance), so this is about which index space the
# derivation can prove it is speaking. ROCR_VISIBLE_DEVICES indexes the KFD GPU-agent list in
# topology-node order — exactly the order the loop below walks. HIP orders by PCI BDF, which
# agrees here only because the nodes happen to be in ascending bus order; that is a coincidence
# this file would then depend on. ROCR removes the question instead of answering it.
#
# WHY A DERIVED FAMILY AND NOT A LITERAL `0,1`. notes/kinoite-north-validation.md records DRM
# numbering reshuffling across kernels and boots. The rule is "keep every GPU agent of the same
# gfx target as the most capable one", which needs no index and no model name: on this box the
# two R9700s report simd_count 128 / gfx_target_version 120001 and the iGPU reports 4 / 100306,
# so the most capable target is 120001 and the answer is `0,1` — but computed, every boot.
# It also generalises the way tensor split needs: a mismatched pair is not a tensor-split
# candidate anyway, so keeping one family is the right answer, not a lucky one.
#
# WHY NOT MATCH THE BUNDLE'S KERNEL LIST INSTEAD. That was the first idea and it is worse. The
# shipped bundle covers gfx1200, gfx1201 and gfx1250 (read off libggml-hip.so 2026-08-30), so a
# literal family filter would have to be a *set*, and gfx1250 is 125000 rather than 1200xx —
# a "1200xx" filter would have silently excluded a supported card. The bundle also lives under
# ~/.local/share/lemonade and is downloaded at runtime, so it is not readable at first start
# and changes with the backend. simd_count is in /sys and is always there.
#
# FAILS OPEN, DELIBERATELY. The file is TRUNCATED FIRST and only then filled in, so every path
# that goes wrong — unreadable sysfs, no GPU agent, a kernel that renames these fields — leaves
# an EMPTY env file rather than a stale or absent one. Empty means podman constrains nothing and
# lemonade starts exactly as it does today, on layer split. Absent would be the opposite:
# `EnvironmentFile=` becomes `--env-file`, and podman treats a missing env file as fatal, so a
# derivation bug would become a container that will not start. That asymmetry is the whole
# reason for the truncate-first ordering.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-gpus << 'GPUEOF'
#!/bin/bash
# Write ROCR_VISIBLE_DEVICES for lemonade.container, derived from KFD topology.
# Pure /sys: no ROCm, no python, no container. Runs as an ExecStartPre on the host,
# because the value has to be in the container's environment before it is created.
#
# Fail open: an empty output file means "constrain nothing", which is the pre-2026-08-30
# behaviour. Never exits nonzero — a derivation problem must not block the server.
set -u

out="${1:?usage: kinoite-lemonade-gpus <output-env-file>}"
nodes=/sys/class/kfd/kfd/topology/nodes

mkdir -p "${out%/*}" 2>/dev/null || true
: > "$out" 2>/dev/null || {
    echo "kinoite-lemonade-gpus: cannot write $out; starting unconstrained" >&2
    exit 0
}
# From here on the file exists and is empty, so every early exit below is a fall back
# to unconstrained rather than a failed container start. No atomic replace is needed:
# podman reads this only in ExecStart, strictly after this helper has exited.

# ROCR_VISIBLE_DEVICES numbers GPU agents only, in KFD node order. Walk the nodes
# numerically and skip CPU agents (simd_count 0, node 0 here) — the count of GPU
# agents emitted so far IS the index, so no index is ever written down.
agents=$(
    for n in $(ls -1 "$nodes" 2>/dev/null | grep -xE '[0-9]+' | sort -n); do
        p="$nodes/$n/properties"
        [ -r "$p" ] || continue
        read -r simd gfx <<< "$(awk '
            $1 == "simd_count"          { s = $2 }
            $1 == "gfx_target_version"  { g = $2 }
            END                         { print s+0, g+0 }' "$p")"
        [ "$simd" -gt 0 ] 2>/dev/null || continue
        [ "$gfx"  -gt 0 ] 2>/dev/null || continue
        printf '%s %s\n' "$gfx" "$simd"
    done
)
[ -n "$agents" ] || {
    echo "kinoite-lemonade-gpus: no GPU agent found under $nodes; starting unconstrained" >&2
    exit 0
}

# The most capable agent's gfx target is the family to keep; NR-1 is its GPU-agent index.
target=$(printf '%s\n' "$agents" | sort -k2,2nr -k1,1nr | awk 'NR == 1 { print $1 }')
csv=$(printf '%s\n' "$agents" | awk -v t="$target" '$1 == t { printf "%s%d", (n++ ? "," : ""), NR - 1 }')
[ -n "$csv" ] || exit 0

printf 'ROCR_VISIBLE_DEVICES=%s\n' "$csv" > "$out"
total=$(printf '%s\n' "$agents" | wc -l)
echo "kinoite-lemonade-gpus: gfx_target_version $target -> ROCR_VISIBLE_DEVICES=$csv (of $total GPU agents)"
GPUEOF
bash -n /usr/libexec/kinoite-lemonade-gpus

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

# No GroupAdd=keep-groups. It was a headless fallback for render/video membership, and it is
# measured unnecessary: /dev/kfd and the render nodes are mode 0666 from systemd-udev's base
# rules, so no group membership is involved. Removing it also sidesteps the known rootless
# flakiness (containers/podman#27876, #28364). Verified by loading a model with it absent.

# Directory: podman adds every node under it, iGPU included. See notes/.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# Unauthenticated API — the 127.0.0.1 prefix is what keeps it off the tailnet.
PublishPort=127.0.0.1:13305:13305

# %h is expanded by systemd, not Quadlet. :z not :Z — :Z would relabel the whole
# model cache on every start, since Quadlet builds a new container each time.
# The huggingface cache is the SHARED model store (see vllm.sh) — same HF hub layout,
# so lemonade and vLLM download once and reuse. llama/ and config/ stay lemonade-specific.
Volume=%h/.local/share/models/huggingface:/opt/lemonade/.cache/huggingface:z
Volume=%h/.local/share/lemonade/llama:/opt/lemonade/llama:z
Volume=%h/.local/share/lemonade/config:/opt/lemonade/.cache/lemonade:z

# Mounting this from /usr/share directly fails: container_t can't read usr_t, and
# :z can't fix it because /usr is read-only. Hence the ExecStartPre copy below.
Environment=LEMONADE_DEFAULTS_PATH=/opt/lemonade/.cache/lemonade/defaults.json

# Which GPU agents llama.cpp may use, computed per start by the ExecStartPre below.
# Keep the `%t` BARE. podman-systemd.unit(5) says to write `./%t` for a path starting with a
# specifier, and that advice is for paths meant to resolve against the unit directory — it is
# wrong here and silently so: `quadlet -dryrun` expands `./%t/...` to
# `/etc/containers/systemd/users/%t/...`, a literal `%t` directory that will never exist, and
# podman treats a missing --env-file as fatal. Bare `%t` is passed through verbatim for systemd
# to expand at runtime, which is what this needs. Verified both ways with `quadlet -dryrun`.
EnvironmentFile=%t/kinoite-lemonade/gpus.env

[Service]
# First start pulls a multi-GB image against systemd's 90s default.
TimeoutStartSec=900

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/huggingface %h/.local/share/lemonade/llama %h/.local/share/lemonade/config
ExecStartPre=/usr/bin/install -m 0644 /usr/share/kinoite/lemonade-defaults.json %h/.local/share/lemonade/config/defaults.json

# Recipe seeds, merged PER KEY (unlike defaults.json above, which is ours to overwrite):
# lemonade reads user_models.json every start and its Web UI writes the same file when a
# user adds a custom model, so the seeder adds only keys that are absent. See the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-seed

# Excludes the iGPU by VISIBILITY before the container exists. Fails open — see the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-gpus %t/kinoite-lemonade/gpus.env

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

## Recipes (baked custom models)

Curated Unsloth Qwen GGUFs, seeded into config/user_models.json on the FIRST start.
List and run (via the Web UI, or the CLI inside the container):

    podman exec lemonade lemonade list
    podman exec lemonade lemonade run user.Qwen3.8-27B     # downloads on first run

    user.Qwen3.8-27B       newest dense, vision+thinking, Developer Role  MTP  UD-Q6_K   23.4 GB   ctx 128K
    user.Qwen3.8-27B-Fast  same model, 4-bit — the speed pick             MTP  UD-IQ4_XS 15.6 GB   ctx 128K
    user.Qwen3.6-27B       dense, vision+thinking                         MTP  Q6_K      22.9 GB   ctx 128K
    user.Qwen3.6-35B-A3B   fast MoE (~3B active), vision+thinking         MTP  UD-Q6_K   30.0 GB   ctx 128K
    user.Qwen3-Coder-30B   agentic coding MoE, 256K native, text-only     --   Q6_K      25.1 GB   ctx 256K

Every recipe with an MTP head available uses it; lemonade turns speculation on by itself
and you do not pass any flags — verified `--spec-type draft-mtp --spec-draft-n-max 3` on
the launched llama-server for both packagings unsloth uses (separate draft file, and head
embedded in the main GGUF). Qwen3-Coder-30B is the exception: no MTP build exists for it.

The two Qwen3.6 entries come from the `-MTP-GGUF` sibling repos rather than the plain ones,
at the identical Q6_K filenames — a repo swap, not a requant. Their sizes above are ~0.3 GB
larger than the plain builds for exactly that reason: the head rides inside the weights.

Measured on the pair for Qwen3.8-27B at IQ4_XS: 30.40 tok/s without MTP, 56.86 with (+87%).
The other entries were not benchmarked — they read more bytes per token, so expect lower
absolute numbers; the speculation multiplier should broadly carry, but that is an
extrapolation. Re-measure before quoting a figure for any entry but the IQ4_XS one.

Qwen3.8-27B is the default all-rounder (MTP + Developer Role); Qwen3-Coder-30B is the
coding workhorse; -Fast trades the Q6 floor for roughly 1.6x fewer weight bytes per token
and has been benchmarked but NOT quality-tested. Q6 quality floor WITH big context —
these ctx exceed one card, so they
use the layer split across both R9700s, which is the AUTOMATIC default here (measured:
~14 GB per R9700, nothing on the iGPU). At 128K the KV cache is large (~33 GB on a dense
27B); if it doesn't fit the pair, drop ctx (~24K single-card) or add q8_0 KV-quant. A load
can no longer spill onto the iGPU — it is excluded automatically (see "Device visibility").

Even more context: add q8_0 KV-quant (-fa -ctk q8_0 -ctv q8_0 in a recipe's llamacpp_args) —
worth up to ~2x on the dense-attention Coder seed, but only ~7.5% measured on a hybrid, see
"Context size & caching". More quality: move a model to Q8_0 in user_models.json. Backend falls back with
`lemonade config set llamacpp.backend=vulkan`.

Seeds are first-run only (like defaults.json below). To pull updated recipes after an
image update, delete and restart:

    rm ~/.local/share/lemonade/config/user_models.json      # and/or recipe_options.json
    systemctl --user restart lemonade

## Storage

    ~/.local/share/models/huggingface     models (SHARED with vLLM — see vllm.md)
    ~/.local/share/lemonade/llama         llama.cpp + ROCm binaries (downloaded)
    ~/.local/share/lemonade/config        config.json, defaults.json, recipes

The huggingface cache is the shared model store: vLLM and any future stack mount the same
path, so a model pulled by either is reused by both. Owned by you (UserNS=keep-id), so
du/rm/backup tools work normally.

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
is why the backend gap is only ~20%. The lever with real headroom is a smaller model or
speculation, not tuning.

CORRECTION (2026-08-20): an earlier version of this note claimed "MTP speculation is what
gets ROCm above the naive ceiling". That was wrong — no MTP was configured when those
numbers were taken. There was no `--spec-type`, no `-md` and no draft checkpoint anywhere
in this file or in the seeded recipes, so those ~35 tok/s are plain, unspeculated decode.
The real MTP numbers, measured directly against llama-server on the R9700 pair with
Qwen3.8-27B-UD-IQ4_XS (14.0 GB), ctx 32768, 512-token runs:

    config                                       rust    python  prose   MEAN
    baseline (no speculation)                    30.45   30.43   30.33   30.40
    --spec-type draft-mtp --spec-draft-n-max 4   53.92   65.25   51.41   56.86

+87%, at 0.45-0.67 draft acceptance and a mean accepted length of 2.8-3.7. The build
already supports all of it — `--spec-type draft-mtp`, `-md`, `-ngld`,
`--spec-draft-n-max`, `--spec-draft-p-min` are all in `llama-server --help` on the
shipped rocm-nightly build. It was simply never switched on.

For scale against the other stack — and this REPLACES the old "~5% ahead, pick on features"
line, which was true only at a short prompt. Re-measured 2026-08-30 at four matched prompt
depths, both stacks the same evening, vLLM at its shipped defaults, at TWO llama.cpp quants
so the comparison is not resting on a 4-bit advantage:

    prompt depth    vLLM FP8    IQ4_XS (14.0 GB)        Q8_K_XL (31.5 GB)
                                layer      tensor       layer      tensor
       189 tok       63.33    69.66 1.10x  92.41 1.46x  51.96 0.82x  77.39 1.22x
     9,479 tok       49.81    61.52 1.24x  80.21 1.61x  47.96 0.96x  78.58 1.58x
    37,763 tok       31.56    48.05 1.52x  71.75 2.27x  42.63 1.35x  62.14 1.97x
    69,751 tok       21.31    43.54 2.04x  67.83 3.18x  34.05 1.60x  55.67 2.61x

THE ENGINE WINS EVEN WHEN IT READS MORE BYTES. Q8_K_XL is 31.5 GB against vLLM's 27.8 GB FP8,
and `-sm tensor` still leads at every depth. So the advantage is not the quantisation — that
was the obvious objection and it has been measured rather than argued.

BUT `-sm layer` — WHAT THIS FILE SHIPS — IS THE QUANT-DEPENDENT ONE, and that is the caveat to
carry. On IQ4_XS it beats vLLM everywhere. On Q8_K_XL it LOSES below ~11K context (0.82x short,
0.96x at 9.5K) and only leads past that crossover. Practical reading: the seeds are safe on the
IQ4_XS `-Fast` entry, but if you move a recipe to a heavy quant AND run short prompts, layer
split is no longer the faster stack — that is the case `-sm tensor` exists for.

Two things still open, both honest: no QUALITY A/B has been run between IQ4_XS, Q8_K_XL and
vLLM's FP8 (bits-per-weight is not a quality metric), and every llama.cpp number here is a
FLOOR because this build has no RCCL. Full tables, method, fits and concurrency arms in
`vllm.md` under "Relationship to lemonade".

Note `--spec-draft-n-max 4` specifically. Upstream's general advice for MTP is `n-max 16
--spec-draft-p-min 0.8`, but that is tuned for other models; for Qwen3.8 a large n-max is
reported to cost throughput, and 4 is what was measured here. Re-measure before changing.

**56.86 is not the ceiling.** The next section measures the same model at **81.75 tok/s** by
adding `-sm tensor`, which composes with MTP rather than competing with it. The iGPU exclusion
it needs is now automatic (see "Device visibility"); what still keeps it out of the seeds is
that `--fit` stops working under tensor split, so every seeded ctx would have to be hand-sized.

### Tensor parallelism: `-sm tensor` works here, `-sm row` is dead

Upstream **deprecated `-sm row`** and replaced it with **`-sm tensor`**, which is real tensor
parallelism — it splits weights *and* KV across the cards, where `row` split only dense weights
(see llama.cpp `docs/multi-gpu.md`). Both are still listed in `--split-mode` on the shipped build,
so the flag being accepted proves nothing. Everything below was measured on the box 2026-08-30 on
the shipped `llamacpp-rocm` **b1305** (llama.cpp `c745be2`, 2026-08-02), in two passes: the
architecture gate and the four conditions on `unsloth/Qwen3.5-4B-MTP-GGUF` (arch **`qwen35`**,
the same GDN-hybrid family as Qwen3.8-27B, so the arch result carries), and the throughput table
on Qwen3.8-27B itself, which is the model the answer actually depends on.

    -sm row     STILL DEAD.  `llama_model_load: error loading model:
                device ROCm0 does not support split buffers`  -> exits. Unchanged, and now
                deprecated upstream as well, so it is not coming back. Stop citing it.

    -sm tensor  WORKS, with four conditions (below). Loads, serves, and generates text
                byte-identical to `-sm layer` at temperature 0.

THE ARCHITECTURE GATE DID NOT FIRE. Upstream documents `-sm tensor` as unimplemented for MoE and
hybrid architectures, failing with *"LLAMA_SPLIT_MODE_TENSOR not implemented for architecture
'...'"*, and lists Jamba, Falcon-H1, Kimi-Linear, Nemotron-H, Mamba and friends. `qwen35` is not
on that list and **that string never appeared** — the model loaded normally. So llama.cpp TP is a
live option for our models, not a dead end. Do not assume the doc's list is exhaustive in either
direction; run the model.

THE FOUR CONDITIONS, each one measured:

1. **`-fa on` is mandatory.** `-fa off` fails at context creation with
   `llama_init_from_model: SPLIT_MODE_TENSOR requires flash_attn to be enabled`. This is also the
   first proof that flash attention works at all on gfx1201 in this build — every arm above ran
   `-fa on` and generated correct text.
2. **The iGPU must be excluded, and this is the trap.** See "invalid kernel file" under
   "Other gotchas" for the full story and the exact string. Short version: tensor split uses
   every VISIBLE device, the gfx120X-only build has no kernels for the gfx1036 iGPU, and the
   run aborts on the first decode. Layer split never hit this because it simply put no layers
   there. **Exclude by VISIBILITY (`HIP_VISIBLE_DEVICES=0,1`), not by `-dev`** — `-dev` covers
   only the main model, and a `--spec-type draft-mtp` run loads a second model that has its own
   device list (`-devd`). Measured on the box: `-sm tensor -dev ROCm0,ROCm1` WITHOUT `-devd`
   still aborts, because the draft head went to all three devices.
3. **`--fit` does not work with it**, so size the context yourself:
   `common_fit_params: failed to fit params to free device memory: llama_params_fit is not
   implemented for SPLIT_MODE_TENSOR, abort`. Harmless (it is a warning and the load continues),
   but it means an unset `-c` is no longer auto-sized to VRAM.
4. **There is no RCCL under it, and that is a CEILING, not a setting.** Every run logs
   `internal AllReduce init failed (n_devices != 2?); falling back to meta-backend butterfly`
   *even with exactly two devices*. RCCL is a build-time option (`-DGGML_HIP_RCCL=ON`) that
   upstream leaves off, and the shipped bundle confirms it was never turned on — read off the
   box 2026-08-30, all three ways agreeing:

       ls   ~/.local/share/lemonade/config/bin/llamacpp/rocm-nightly | grep -i rccl   # nothing
       ldd  .../libggml-hip.so | grep -i rccl                                         # nothing
       nm -D .../libggml-hip.so | grep -i rccl                                        # nothing

   So every cross-GPU reduction goes through ggml's generic butterfly path, and no environment
   variable can change that — lifting it means building llamacpp-rocm yourself, i.e. leaving
   lemonade's prebuilt binaries. There IS a runtime selector, `GGML_CUDA_ALLREDUCE`, and it does
   accept `internal` and `nccl` (a bogus value logs `unknown GGML_CUDA_ALLREDUCE value: bogus`,
   so those two are real). Both were tried on 2026-08-30 and **both still fall back to butterfly**
   — a selector cannot conjure a library that was never linked.
   `GGML_CUDA_P2P=1` (opt-in at runtime, and documented to break with IOMMU on some boards)
   changed nothing observable here — it neither helped nor broke anything. **Everything in the
   table below is therefore a FLOOR for tensor split, not a verdict on it.**

WHAT IT IS ACTUALLY WORTH — MEASURED ON THE 27B, 2026-08-30. This is the case tensor split
exists for, and it wins by a lot. Qwen3.8-27B-UD-IQ4_XS (14.0 GB), `-ngl 99 -c 32768`,
`HIP_VISIBLE_DEVICES=0,1`, fresh load per arm, thinking off, 512-token runs, decode timed
first-content-token to last (`~/bench/tp.sh`, same method as every other table here):

    arm                 rust   python  prose    MEAN    vs layer   card A   card B      pair
    -sm layer  + MTP    53.78   64.99  51.06   56.61        --     9099 M  11739 M   20838 M
    -sm tensor + MTP    82.76   92.32  70.16   81.75    +44.4%    10353 M  10353 M   20706 M
    -sm layer  no MTP   30.43   30.41  30.42   30.42        --     7820 M   8955 M   16775 M
    -sm tensor no MTP   42.20   42.11  42.11   42.14    +38.5%     8296 M   8296 M   16592 M

Both layer arms reproduce the recorded baselines to within 0.5% (56.86 and 30.40 above), and the
MTP arm reproduces them with the SAME acceptance figures, so the two tensor arms are being
compared against a live baseline rather than a remembered one.

Four things to read out of that table:

- **`-sm tensor` and `--spec-type draft-mtp` COEXIST.** No conflict, no gate, no silent
  disabling: acceptance under tensor split is 0.464 / mean accepted length 2.85, statistically
  the same as layer split's 0.448-0.476 / 2.79-2.90. The two levers COMPOSE — MTP is worth 1.86x
  on layer split and 1.94x on tensor split — so you do not have to choose. Together they are
  **2.69x** the unspeculated layer-split baseline (30.42 -> 81.75).
- **Tensor split balances the pair exactly** (10353/10353 and 8296/8296, weights and KV together)
  where layer split does not (9099/11739 — a 2.6 GB imbalance). It also uses slightly LESS total
  VRAM. That balance is the mechanism: layer split pipelines, so at batch 1 one card computes
  while the other waits, and only tensor split has both cards reading weights at once.
- **The no-MTP arms are dead flat across all three workloads** (30.43/30.41/30.42 and
  42.20/42.11/42.11). That is the bandwidth-bound signature. Tensor split moves the ceiling from
  30.4 to 42.1, i.e. it realises ~1.39x of a theoretical 2x — the rest goes to the reduction.
- **THIS IS A FLOOR.** The butterfly-fallback warning in condition 4 still appears at 27B — twice
  per MTP run, once for the main model and once for the draft — so every tensor arm above ran on
  the slow generic reduction with no RCCL. A build with RCCL should be faster; nothing here says
  how much faster.

One asymmetric cost worth knowing before baking: `-sm tensor` disables backend sampling
(`set_sampler: backend sampling not supported with SPLIT_MODE_TENSOR; using CPU`, followed by
`spec common_specu: backend offload failed for seq_id=N; using CPU sampler` for every slot). So
the MTP draft sampler runs on the CPU under tensor split and on the GPU under layer split. It is
already priced into the +44.4% — it is a reason the number is not higher, not a reason to doubt it.

**q8_0 KV-quant and `-sm tensor` are NOT mutually exclusive on this build** — upstream's doc says
quantized KV with tensor split "is not implemented and trying to use it will result in an error",
and on b1305 it simply works: `-sm tensor -fa on -ctk q8_0 -ctv q8_0` loads, serves, produces
identical output, and at ctx 65536 saves 477 MiB across the pair (6352 -> 5875 MiB). The saving is
small *for this model* because a GDN hybrid keeps only 16-of-64 full-attention layers — most of
its cache is constant-size SSM state that KV-quant does not touch. So the `-fa -ctk q8_0`
suggestion below stands for any split mode; just size the expected saving off the full-attention
layer count, not off total context.

The iGPU is EXCLUDED AUTOMATICALLY as of 2026-08-30 — the container only ever sees the
R9700s, so a load can no longer spill onto gfx1036 and no pinning is needed. See "Device
visibility" below for how that is derived and how to check it. To confirm the split itself:

    podman logs lemonade | grep -iE 'buffer size|assigned|ROCm[0-9]'

### Device visibility: the iGPU is excluded automatically

Since 2026-08-30 the container sees ONLY the R9700s. `lemonade.container` runs an
ExecStartPre that reads KFD topology and writes `ROCR_VISIBLE_DEVICES` into an
EnvironmentFile, which podman passes into the container. Nothing to configure, and no
index is hard-coded — it is recomputed every start.

Check what it derived, in order of how much you have to type:

    journalctl --user -u lemonade | grep kinoite-lemonade-gpus
    # kinoite-lemonade-gpus: gfx_target_version 120001 -> ROCR_VISIBLE_DEVICES=0,1 (of 3 GPU agents)

    cat /run/user/$UID/kinoite-lemonade/gpus.env       # the file podman actually reads
    podman exec lemonade printenv ROCR_VISIBLE_DEVICES # what the server actually got

Run the derivation by hand against the live machine without touching the service:

    /usr/libexec/kinoite-lemonade-gpus /tmp/gpus.env && cat /tmp/gpus.env

The rule it applies: keep every GPU agent whose `gfx_target_version` matches the agent with
the most SIMDs. On this box the two R9700s are 128 SIMDs / 120001 and the iGPU is 4 / 100306,
so the answer is `0,1`. It counts GPU agents in KFD node order and skips CPU agents, which is
exactly how `ROCR_VISIBLE_DEVICES` is indexed, so the index never has to be written down.

**AN EMPTY `gpus.env` IS NOT A FAILURE, IT IS THE FALLBACK.** The helper truncates the file
first and only then fills it in, so anything that goes wrong leaves it empty — and empty means
podman constrains nothing and lemonade starts on layer split exactly as it did before this
existed. That is deliberate: `EnvironmentFile=` becomes `--env-file`, podman treats a MISSING
env file as fatal, so the failure mode had to be "empty" rather than "absent". If you see an
empty file, look for the warning in the journal:

    kinoite-lemonade-gpus: no GPU agent found under /sys/class/kfd/kfd/topology/nodes; ...

To override — a card you want left out, or a derivation that got it wrong — use a QUADLET
drop-in, not `systemctl --user edit`. `systemctl edit` patches the generated .service, which
cannot change the podman command line Quadlet built; a `.container.d` drop-in can:

    mkdir -p ~/.config/containers/systemd/lemonade.container.d
    cat > ~/.config/containers/systemd/lemonade.container.d/10-gpus.conf << 'END'
    [Container]
    Environment=ROCR_VISIBLE_DEVICES=0
    END
    systemctl --user daemon-reload && systemctl --user restart lemonade

That emits `--env` ALONGSIDE the generated `--env-file`, and `--env` wins — verified both
ways on 2026-08-30 (`--env-file` setting `0,1` plus `--env` setting `7` yields `7` in the
container). So the drop-in overrides the derivation without having to disable it.

Two things NOT to do. Do not add `-dev ROCm0,ROCm1` to a recipe's `llamacpp_args` — it covers
the main model only, and every MTP recipe here loads a draft model with its own device list
(see the "invalid kernel file" gotcha). And do not change `EnvironmentFile=%t/...` to `./%t/...`
in the quadlet: podman-systemd.unit(5) suggests that form for specifier paths, but Quadlet then
resolves it against the unit directory and emits a literal `%t` path segment that will never
exist — which, since a missing env file is fatal to podman, is a container that will not start.
Bare `%t` is passed through for systemd to expand. Both forms confirmed with `quadlet -dryrun`.

## Context size & caching

The model download cache is already persistent (see Storage above) — models pull once.
llama.cpp also reuses the KV cache of a request's common prefix automatically; nothing to
configure for that.

The lever for LONG context is VRAM for the KV cache, which is SEPARATE from weights and
grows linearly with ctx_size. For the dense 27Bs (64 layers, 4 KV heads, head_dim 256)
it is ~0.25 GB per 1K tokens at fp16 — so 128K ~= 32 GB, on TOP of the ~23 GB weights;
the MoEs are ~0.10 GB/1K (2.5x lighter). So a 27B Q6 at 128K is ~56 GB total — it only
fits by SPLITTING across both R9700s, which is what the seeded contexts assume.

That split is AUTOMATIC here — default -sm layer already spreads layers (and their KV)
across both R9700s and, measured at ctx 32768, put nothing on the gfx1036 iGPU (only its
20 MiB framebuffer). Layer split is what the seeds assume and what is baked. It is NOT the fastest
mode — `-sm tensor` measured +44% on the 27B with MTP (see "Tensor parallelism" above) — but it is
the one that needs no per-recipe arithmetic: tensor split disables `--fit`, so switching a recipe
to it means hand-sizing that recipe's ctx as well. (The iGPU exclusion tensor split also needs is
no longer part of that cost — it is automatic now, see "Device visibility".) One thing to watch at
128K, where total memory is far larger: it must still fit the 2x32 GB pair. Bigger context also
costs prompt-processing time, so a smaller ctx is fine for quick edits.

KV-cache quantization roughly halves that KV footprint with little quality loss. Add to a
recipe's llamacpp_args in recipe_options.json:

    -fa -ctk q8_0 -ctv q8_0     # q8_0 ~halves the GROWING KV; q4_0 ~quarters it

**Flash attention is verified working on gfx1201** (2026-08-30, llamacpp-rocm b1305) and q8_0 K+V
loads and generates correctly, so the old "unverified, confirm -fa first" caveat is retired.

WHAT IS NOT VERIFIED IS THE SIZE OF THE WIN, AND FOR THE HYBRIDS IT IS SMALL. "Halves KV" is a
DENSE-attention rule. Measured on Qwen3.5-4B (arch qwen35, the same hybrid family as the two
Qwen3.8/3.6 27B seeds) at ctx 65536: 6352 -> 5875 MiB across the pair, a 477 MiB / ~7.5% saving,
because only 16 of 64 layers hold a growing cache and the other 48 are constant-size SSM state
that KV-quant does not touch. Where it should still pay properly is user.Qwen3-Coder-30B — dense
attention, ~0.098 GB/1K, seeded at 256K — and that arm has NOT been run: the GGUF is not in the
cache and the pull was dropped on 2026-08-30 because nothing on this box runs that model. So the
dense number is UNKNOWN, not assumed. Measure it before baking a KV-quant default anywhere, and
do not size any seed against an assumed 2x.

## Coding / agent use

Two recipes suit agentic coding: user.Qwen3-Coder-30B (tuned for tool-calling / Codex-style
agents, 256K native ctx) and user.Qwen3.8-27B (Developer Role, plus vision + reasoning).
Coder is the default driver — MoE so it's fast, Q6_K, and its native 256K is the seeded
ctx (which the automatic two-card split makes room for).

Point your agent (opencode, aider, Continue, ...) at lemonade's OpenAI-compatible endpoint:

    base URL   http://127.0.0.1:13305/api/v1      (any api key; it's ignored)
    model      user.Qwen3-Coder-30B

Context: agentic coding uses far more than chat (multi-file, diffs, tool output, scratchpad).
The Coder seed is already the native 262144 (256K), which needs the two-card split — see
"Context size & caching". For a quick single-card session, drop ctx or add q8_0 KV-quant.

Keep it warm: an agent resends a large, mostly-unchanged prompt every turn, and llama.cpp
reuses the common prefix's KV automatically — but only while the model stays loaded. Enable
linger (below) and don't let it idle-unload, or you re-process the whole prompt each turn.

## Other gotchas

### "invalid kernel file" — three devices are visible and one of them is the iGPU

    ggml/src/ggml-cuda/ggml-cuda.cu:106: ROCm error
    ROCm error: invalid kernel file
      hipGetLastError()

The server LOADS, then core-dumps on the first decode. It reads like a bug in whatever you
just switched on; it is not. The llamacpp-rocm build is gfx120X-only and this box has THREE
ROCm devices — ROCm0 and ROCm1 are the R9700s (gfx1201) and **ROCm2 is the Granite Ridge
iGPU (gfx1036), for which the build contains no kernels at all.** Anything that touches every
visible device therefore dies the moment it dispatches.

This is now the SECOND consumer of the iGPU-exclusion rule, and the two hit differently:

    -sm tensor              splits weights and KV across every VISIBLE device -> hits it
    --spec-type draft-mtp   the draft model has its OWN device list, defaulting to all -> hits it
    -sm layer (the default) just puts no layers on the iGPU -> never hit it, which is why
                            nothing in this image pins devices today

The `-dev` flag is NOT a sufficient fix, and this cost real time on 2026-08-30: `-sm tensor
-fa on -dev ROCm0,ROCm1` still aborts, because `-dev` restricts the MAIN model only and the
MTP draft head went to all three. There is a matching `-devd`/`--spec-draft-device`, but you
have to know it exists and lemonade does not emit one.

**Fix it at visibility, not per flag** — one setting, covers every model the process loads:

    HIP_VISIBLE_DEVICES=0,1     # what ~/bench/*.sh uses
    ROCR_VISIBLE_DEVICES=0,1    # indexes GPU AGENTS, so 0,1 is the pair

Both were verified on 2026-08-30 with `-sm tensor` + `--spec-type draft-mtp`, each on its own
with no `-dev` and no `-devd`: same VRAM (10252 MiB per card), same draft acceptance, no abort.

**IN THE CONTAINER THIS IS ALREADY DONE FOR YOU** since 2026-08-30 — see "Device visibility"
under "Performance notes". If you hit this error from `systemctl --user start lemonade`, the
derivation did not run or came up empty; check it before debugging anything else. The section
above is what still applies when you run the bundled `llama-server` BY HAND, where nothing
sets the variable for you.

Re-derive `0,1` rather than trusting it — DRM and device indices move with kernels and slots:

    grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties

120001 is an R9700, 100306 the iGPU; node 0 is the CPU and is not a GPU agent, so subtract
one from the node number to get the agent index. Today: nodes 1,2 = R9700s -> agents 0,1.

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

Already handled — `kinoite-linger.service` runs `loginctl enable-linger` for every regular
account at boot, so a hand-started server outlives the session that started it (including an
SSH session). It cannot be baked as a file: linger is recorded under /var/lib/systemd/linger,
and /var is machine-local state rather than image content, so it is re-asserted each boot.

Confirm with `loginctl show-user $USER -p Linger` (want `Linger=yes`). Note linger starts
nothing by itself: this Quadlet has no [Install] section.

To opt out, `systemctl mask kinoite-linger.service` and then `loginctl disable-linger <user>`.
Doing only the second half does not stick — the service re-asserts linger on the next boot,
which is the whole point of it.

## Suspend / resume

Handled automatically by `kinoite-llm-sleep.service`, the same hook that covers the vLLM stack.
If lemonade was running when the box went to sleep, it will be running again a minute or so after
you wake it; if you stopped it by hand first, it stays stopped.

It is not optional politeness. amdgpu evicts VRAM into system RAM to suspend, and this box has
64 GB of RAM against 64 GB of VRAM across the two R9700s. A loaded model does not fit, and the
result is not a failed suspend but a **hung machine** that needs the power button. lemonade holds
`/dev/kfd` and real VRAM, so it is torn down alongside vLLM.

Full detail, the manual-test recipe that exercises both edges without suspending, and the opt-out
are in `/usr/share/kinoite/vllm.md` under "Suspend / resume".
EOF
