---
date: 2026-09-13
subject: R9V vLLM depth cost on Qwen3.8-27B-FP8 with the MTP drafter on ROCM_ATTN or TRITON_ATTN and the KV cache in HND or NHD
harness: ~/bench/r9v/gdnab/gdnab.sh (GDNAB_DRAFT_ATTN, GDNAB_KV_LAYOUT), orchestrated by gdnab-arms.sh and gdnab-arm-retry.sh, driving ~/bench/depth.py; raw output ~/bench/r9v/gdnab/{gdnab3,gdnab4,gdnab5}.log, serve-off-nhd.log, serve-off-hnd.log and their -try1 failed starts (off-repo, on the box)
box: kinoite-north
---

# Drafter attention backend and KV layout in R9V's vLLM

## What was measured

[runs/2026-09-13-fused-gdn-kernel-27b-fp8](2026-09-13-fused-gdn-kernel-27b-fp8.md)
found R9V's vLLM spending 3.99 ms per 1K tokens of context on Qwen3.8-27B-FP8.
Production vLLM spent 1.50 in
[runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md).

That record's serve logs show how the KV cache lands in `LBHNC` (HND):

- `--attention-backend TRITON_ATTN` reaches only the target model, so the MTP
  drafter falls back to ROCM_ATTN.
- ROCM_ATTN declares `(LHBNC, LBHNC)`; TRITON_ATTN declares nothing, so the
  drafter's list decides.
- The model mixes GDN and attention specs, which limits the candidates to
  block-compact layouts. That leaves `LBHNC`.
- As a result `LBNHC` (NHD) cannot be selected while the drafter is on ROCM_ATTN.

Two runs here repeat that record's kernel-off arm exactly: same image, model,
flags, env, wrapper mount and harness (`depth.py - 512 3 8000`). Each moves the
drafter to TRITON_ATTN through
`--speculative-config '{"method":"mtp","num_speculative_tokens":4,"attention_backend":"TRITON_ATTN"}'`
and sets `VLLM_KV_CACHE_LAYOUT`.

| configuration | drafter attention | KV layout | source |
|---|---|---|---|
| default | ROCM_ATTN | LBHNC | the kernel record's off arm |
| Triton drafter, HND | TRITON_ATTN | LBHNC | this record |
| Triton drafter, NHD | TRITON_ATTN | LBNHC | this record |

Each new run's serve log confirmed the resolved layout (`Using … KV cache
layout.`) and showed no ROCM_ATTN override. The HND run isolates the drafter
backend against the default; the NHD run isolates the layout against the HND run.

Both new configurations failed their first start. The changed drafter graph
compiled cold (Dynamo transform 7.95 s; graph compile 18.68 s for NHD, 17.20 s
for HND), and vLLM's KV-memory check then refused a 131,072-token request: 4.74
GiB needed, with 3.77 GiB (NHD) and 3.99 GiB (HND) available. Each second start,
with identical flags and a warm compile cache, was healthy after 50 s. Available
KV memory was 6.22 GiB (172,077 tokens) for NHD and 6.31 GiB (174,274 tokens) for
HND.

## Numbers

ms per target forward pass, with mean accepted length in brackets:

| point | default | Triton drafter, HND | Triton drafter, NHD |
|---|---|---|---|
| rust (28 tok) | 64.49 (3.012) | 56.93 (3.397) | 57.05 (3.212) |
| python (32 tok) | 64.72 (3.552) | 57.19 (3.503) | 56.74 (3.650) |
| prose (31 tok) | 64.46 (2.819) | 56.74 (3.097) | 57.20 (2.893) |
| 189 | 65.13 (3.984) | 57.56 (4.016) | 57.66 (3.931) |
| 9,479 | 101.38 (3.657) | 86.11 (3.842) | 86.31 (3.710) |
| 37,763 | 217.91 (3.508) | 173.01 (3.934) | 175.91 (3.417) |
| 69,751 | 342.59 (3.662) | 272.01 (3.745) | 272.83 (3.691) |
| slope, 189 → 69,751 tokens | 3.99 ms per 1K | 3.08 ms per 1K | 3.09 ms per 1K |

The two effects, separated:

| point | drafter backend: default → Triton drafter, HND | layout: HND → NHD, Triton drafter |
|---|---|---|
| control mean | −7.60 ms (−11.8%) | +0.04 ms (+0.1%) |
| 189 | −7.57 ms (−11.6%) | +0.10 ms (+0.2%) |
| 9,479 | −15.27 ms (−15.1%) | +0.20 ms (+0.2%) |
| 37,763 | −44.90 ms (−20.6%) | +2.90 ms (+1.7%) |
| 69,751 | −70.58 ms (−20.6%) | +0.82 ms (+0.3%) |

Reliability of the individual points:

- In the two new runs, the decode tok/s min–max spread is under 2% at every point
  except NHD at 37,763 tokens (3.4%).
- In the default run it is 9.5% at 37,763 and 4.4% at 69,751.

Decode tok/s:

| configuration | control mean | 69,751 tokens |
|---|---|---|
| default | 48.43 | 10.69 |
| Triton drafter, HND | 58.50 | 13.77 |
| Triton drafter, NHD | 57.07 | 13.53 |

Speculative counters at the end of each run, sanity prompt and warm-up included:

| configuration | drafts | accepted / draft tokens |
|---|---|---|
| Triton drafter, NHD | 4,577 | 11,066 / 18,308 |
| Triton drafter, HND | 4,386 | 11,233 / 17,544 |

The host MemAvailable minimum was 49,772 MiB (NHD) and 49,648 MiB (HND). Both
runs answered the sanity prompt coherently.

## What it means

**The KV layout is not the cause.** With the drafter on TRITON_ATTN, HND and NHD
are within 0.3% at every point except 37,763 tokens (+1.7%, NHD's noisiest point).

**The drafter's attention backend is.** Moving the drafter from ROCM_ATTN to
TRITON_ATTN cut 7.60 ms per pass on the control and 70.58 ms (−20.6%) at 69,751
tokens. The slope fell from 3.99 to 3.08 ms per 1K tokens, and control decode rose
from 48.43 to 58.50 tok/s.

**A likely mechanism, from code reading only.** R9V's `rocm_attn.py` says its
native HIP kernels need `LHBNC`, and that on `LBHNC` it runs stride-aware Triton
fallbacks "without the native kernels". This model's mixed specs force `LBHNC`.
Which path actually executed was not traced.

**It closes 36% of the gap to production, not all of it.** The Triton-drafter
slope is 3.08 against production's 1.50, which came from a different image and
stack on 08-31. At 69,751 tokens this configuration still takes 1.64x
production's time per pass. At 189 tokens it is 3.20 ms faster than production.
The rest of the slope difference is not established.

Not measured:

- whether production vLLM pays a similar drafter cost. Its 09-04 log shows the
  same ROCM_ATTN override line, which in R9V's logs follows the drafter load, on a
  vLLM that predates the layout-resolution code.
- the Triton drafter combined with the fused GDN kernel
- which ROCM_ATTN path, native or fallback, executed in the default configuration
- repeats: one run per configuration
