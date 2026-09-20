---
date: 2026-09-19
subject: "which attention backend makes fp8 KV viable on gfx1201, and where it overtakes bf16"
harness: ~/bench/vllm-kvarm/prodab-kv.sh (off-repo, on the box) driving ~/bench/depth.py for the D arms and ~/bench/depth-deep.py for the E arms, both as `- 512 3 8000`; pool figures parsed by ~/bench/kvdepth/kvparse.py; orchestrated by ~/bench/kvdepth/all.sh. Raw output on the box: ~/bench/kvdepth/{arm,serve,sampler}-{d-triton-bf16,d-rocm-fp8,d-rocm-bf16,d-aiter-fp8,d-aiter-bf16,e-triton-bf16-deep,e-aiter-fp8-deep}.log and kv-*.txt
box: kinoite-north
---

# Which attention backend makes fp8 KV viable, and where it overtakes bf16

## What was measured

[runs/2026-09-19-vllm-fp8-kv-dtype-depth](2026-09-19-vllm-fp8-kv-dtype-depth.md)
found that `--kv-cache-dtype fp8` halves KV density exactly and admits 262,144,
but costs 9.0x the depth slope on `TRITON_ATTN`. It listed as not measured
"whether the slope collapse is specific to `TRITON_ATTN`" and called that the arm
that would decide whether fp8 KV is usable on production vLLM at all. **This run
supersedes that record's conclusion.** It is usable, on a backend that record did
not test.

Reading `triton_attn.py` in this image first, to know what to expect: the guard
that rejects fp8 KV without SM89 sits inside `if current_platform.is_cuda()`, so
ROCm gets no capability check; `supports_quant_query_input` is
`current_platform.is_cuda()`, so it is False here and `q_descale` is never set.
The fp8 path therefore runs a bf16 query against an fp8 KV cache with `k_descale`
and `v_descale` expanded per sequence — dequantise-on-read rather than a native
fp8 GEMM. That is consistent with a cost proportional to context; it is source
reading, not measurement, and the arms below are what establish the numbers.

`rocm.py` offers five non-MLA backends: `ROCM_ATTN`, `ROCM_AITER_FA`,
`ROCM_AITER_UNIFIED_ATTN`, `TRITON_ATTN`, `TURBOQUANT`. Three were tried.

**Launch path.** As in the superseded record — a `prodab.sh` derivative running a
patched copy of the baked launcher, shipped quadlet untouched,
`~/.config/containers/systemd/users/` empty throughout. One line was added to the
launcher patch for this run, taking it to three:

```bash
    --attention-backend "${VLLM_ATTN_BACKEND:-TRITON_ATTN}" \
```

Unset, the default is unchanged.

**Every arm gates on the engine's own backend report.** `prodab-kv.sh` greps
`Using <X> backend` out of the serve log and voids the arm unless the requested
backend appears, because a silent fallback would have measured `TRITON_ATTN`
five times. The drafter is separately pinned to `TRITON_ATTN` by the shipped
speculative config, so both names appear; log ordering separates them:

    Using ROCM_AITER_UNIFIED_ATTN backend (selected via --attention-backend).
    Loading drafter model...
    Using TRITON_ATTN backend (selected via --attention-backend).

**D arms** all ran the shipped memory config — `gpu_memory_utilization` 0.80,
`--max-model-len` 131072 — so the only variables are the backend and the KV
dtype. **E arms** extend the two survivors to ~170K with `depth-deep.py`, at a
matched `gpu_memory_utilization` 0.90 and `--max-model-len` 176000. 0.90 is
needed because vLLM refuses to start when the pool is smaller than
`max_model_len`, and bf16 at 0.80 holds only 174,274 tokens. The superseded
record measured the slope to be independent of utilisation and `max_model_len`
across three arms within 0.5%, so this buys the context without moving what is
being compared.

## Numbers

### D — backend against KV dtype, shipped memory config

ms per target pass, 512 tokens, 3 reps, medians. Spread under 0.1% everywhere.

| depth | TRITON bf16 | TRITON fp8 † | ROCM_ATTN bf16 | ROCM_ATTN fp8 | AITER fp8 |
|---|---|---|---|---|---|
| control mean (tok/s) | 56.27 | 51.55 | 45.95 | 44.78 | 47.10 |
| 189 | 59.79 | 63.39 | 72.22 | 76.08 | 69.87 |
| 9,479 | 67.59 | 135.35 | 108.20 | 179.03 | 78.57 |
| 37,763 | 92.34 | 356.26 | 219.47 | 492.24 | 100.83 |
| 69,751 | 120.11 | 605.63 | 345.21 | 842.76 | 125.61 |
| **slope ms/1K** | **0.8671** | **7.795** | **3.9244** | **11.0216** | **0.8013** |
| tok/s at 69,751 | 31.58 | 6.78 | 11.41 | 4.07 | 27.67 |
| pool (tokens) | 174,274 | 200,540 | 154,296 | 280,300 | 201,309 |

† the a2 arm of the superseded record, same configuration, quoted not re-run.

fp8 penalty by backend, as the ratio of its own two slopes:

| backend | bf16 | fp8 | penalty |
|---|---|---|---|
| TRITON_ATTN | 0.8671 | 7.795 | **9.0x** |
| ROCM_ATTN | 3.9244 | 11.0216 | **2.8x** |
| ROCM_AITER_UNIFIED_ATTN | not achievable | 0.8013 | — |

**`ROCM_AITER_UNIFIED_ATTN` cannot run bf16 KV on this hardware.** The arm failed
in warm-up with

    triton.runtime.errors.OutOfResources: out of resource: shared memory,
    Required: 65792, Hardware limit: 65536

from `unified_attention`. It overruns gfx1201's 64 KiB LDS by 256 bytes at bf16;
at fp8 the K/V tiles are half-size and it fits. So that backend's bf16 baseline
is not missing by accident — it is unreachable at default block sizes, and the
backend works here *because* of fp8, not despite it.

### E — the two survivors out to ~170K, matched

`gpu_memory_utilization` 0.90, `--max-model-len` 176000, both arms.

| depth | AITER fp8 ms/pass | TRITON bf16 ms/pass | AITER − TRITON |
|---|---|---|---|
| 189 | 70.16 | 59.97 | +10.19 |
| 9,479 | 78.85 | 68.08 | +10.77 |
| 37,763 | 100.98 | 92.20 | +8.78 |
| 69,751 | 125.79 | 120.19 | +5.60 |
| 149,739 | 187.84 | 189.34 | **−1.50** |
| 169,251 | **200.74** | 206.38 | **−5.64** |

| | AITER fp8 | TRITON bf16 |
|---|---|---|
| slope 189 → 69,751 | 0.7997 | 0.8657 |
| slope 69,751 → 169,251 | 0.7533 | 0.8662 |
| slope 189 → 169,251 | 0.7724 | 0.8660 |
| tok/s at 169,251 | 17.78 | 17.81 |
| mean accepted length at 169,251 | 3.569 | 3.676 |
| KV memory | 7.17 GiB | 7.21 GiB |
| pool | **380,042 tok** | 204,581 tok |
| MiB/token | 0.01932 | 0.03609 |
| max concurrency @ 176,000 | **2.16x** | 1.16x |
| run-wide acceptance | 3.504 | 3.523 |
| launch to healthy | 110 s | 110 s |
| peak VRAM per card | 25,379 MiB | 25,613 MiB |

## What it means

**fp8 KV is not inherently broken on this hardware; two of three backends are.**
`ROCM_AITER_UNIFIED_ATTN` runs fp8 KV at a slope of 0.8013 ms/1K, *better* than
`TRITON_ATTN` manages with bf16 (0.8671). The superseded record's implication —
that fp8 KV costs 9x at depth — is true only of `TRITON_ATTN`, and its open
question is answered.

**The collapse is not one backend's gap, and it is not uniform either.**
`TRITON_ATTN` pays 9.0x for fp8 and `ROCM_ATTN` pays 2.8x, but `ROCM_ATTN` is so
much slower at bf16 (3.92 against 0.87) that it loses in absolute terms at every
depth. A backend's fp8 penalty and its baseline are independent, and both matter.

**AITER+fp8 overtakes TRITON+bf16 between 69,751 and 149,739 tokens.** Measured,
not extrapolated. Interpolating the difference across those two points puts the
crossover near 133,000. An earlier linear extrapolation from the D arms put it at
~153,000 and was wrong by 20K, because both slopes flatten and they do not
flatten equally: AITER goes 0.7997 → 0.7533 over the two spans while TRITON bf16
stays flat at 0.8657 → 0.8662.

**At this box's operating depth AITER+fp8 wins on pass cost and on pool at
once.** At 169,251 tokens it is 200.74 ms/pass against 206.38, 2.7% cheaper,
while holding 380,042 KV tokens against 204,581 from 0.6% less KV memory — 1.86x
the pool and 2.16x the concurrency at 176,000 tokens per request. The sessions
this box runs sit at 150–170K
([runs/2026-09-18-kv-quant-and-slot-count](2026-09-18-kv-quant-and-slot-count.md)),
which is past the crossover.

**In tok/s the 170K comparison is a dead heat, and ms/pass is the honest
number.** 17.78 against 17.81. AITER's pass is cheaper but its mean accepted
length at that point is lower, 3.569 against 3.676, and tok/s multiplies the two.
`depth.py` reports ms/pass precisely because it is the quantity deterministic in
depth; run-wide acceptance across the whole series is 3.504 against 3.523, a 0.5%
difference, so nothing here suggests fp8 on AITER costs acceptance systematically.

**Below ~133K, bf16 on TRITON_ATTN is still the better configuration**, by
10.19 ms/pass at 189 tokens and 5.60 at 69,751. This is a depth-dependent choice,
not a winner.

**The bf16 control reproduces the 09-18 record exactly.** Same image, three weeks
apart: control mean 56.27 against 56.28 with identical acceptance 3.346, pool
6.31 GiB / 174,274 tokens / 0.03708 MiB/token to the digit, and ms/pass within
0.10 at every one of seven points. The 9x denominator is measured in this
session, not carried over. It also came up on one start where 09-18 needed two,
on a compile cache that is now warm.

**A candidate configuration, not an adoption.** `ROCM_AITER_UNIFIED_ATTN` with
`--kv-cache-dtype fp8` is the first thing measured here that improves on the
shipped launcher at the depth this box actually runs. Nothing is adopted by this
work, and the list below is what stands between it and that.

Nothing is adopted. The shipped quadlet, launcher and `gpu_memory_utilization`
0.80 are unchanged; no shadow unit was created; lemonade was restored and both
cards read 57 MiB at the end.

Not measured:

- **output quality under fp8 KV on AITER, at any depth.** This is the largest
  gap. The fp8/bf16 quality pair in
  [runs/2026-09-19-radiance-depth-and-fp8-kv-quality](2026-09-19-radiance-depth-and-fp8-kv-quality.md)
  was run on radiance's R4D, not on this backend, and found no effect at a power
  of roughly 5 points. One sanity prompt per arm is all that was checked here
- **`ROCM_AITER_FA` and `TURBOQUANT`**, the two backends not tried. `ROCM_AITER_FA`
  needs `VLLM_ROCM_USE_AITER_MHA` and was not enabled
- **concurrency, agentic replay, TTFT and prefill** on any of these backends.
  Decode only, timed first content token to last. The 2.16x concurrency figure is
  the engine's own arithmetic, not a measured 2-way run
- **tool calling and prefix caching correctness** on AITER. The shipped
  `qwen3_coder` parser and prefix caching were on but only the depth probe ran
- **stability.** One run per arm, three reps. No repeat of any D or E arm, and no
  sustained or overnight soak on AITER
- **whether the crossover moves** with utilisation, `max_model_len`, batch size or
  the drafter's backend. Measured at one configuration each side
- an AITER bf16 baseline, which this hardware cannot produce at default block
  sizes. Reducing block sizes or `num_stages` would change the kernel and break
  the comparison, so it was not attempted
