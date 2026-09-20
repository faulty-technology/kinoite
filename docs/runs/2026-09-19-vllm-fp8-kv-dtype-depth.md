---
date: 2026-09-19
subject: "vLLM FP8 27B: what --kv-cache-dtype fp8 buys in context and costs in depth"
harness: ~/bench/vllm-kvarm/prodab-kv.sh (off-repo, on the box), a derivative of ~/bench/prodab/prodab.sh driving ~/bench/depth.py with the same invocation as the 09-18 record, `depth.py - 512 3 8000`; pool figures parsed by ~/bench/kvdepth/kvparse.py; orchestrated by ~/bench/kvdepth/all.sh. Raw output on the box: ~/bench/kvdepth/{arm,serve,sampler}-{a1-profile,a1-pinned,a2}.log and kv-*.txt
box: kinoite-north
---

# vLLM FP8 27B: what fp8 KV buys in context and costs in depth

## What was measured

[runs/2026-09-18-vllm-0271-fp8-depth](2026-09-18-vllm-0271-fp8-depth.md) ruled vLLM
out of this box on context: a 6.31 GiB pool, 174,274 tokens, `max_model_len`
131,072, against sessions that run 150–170K. That arm used
`gpu_memory_utilization` 0.80, no `--kv-cache-dtype` and no explicit
`--kv-cache-memory`, where
[runs/2026-09-15-radiance-mxfp4-dflash](2026-09-15-radiance-mxfp4-dflash.md) used
0.98, fp8 KV and a measured pin and held 943,581 tokens. Radiance's checkpoint is
the larger of the two (18.04 GiB against 17.56), so the pool gap is not weight
savings. This run asks which part of the memory config the 09-18 ceiling came
from, and what that part costs.

**Image.** `kyuz0/vllm-therock-gfx1201:rocm7.14.0-torch2.11.0-vllm0.27.1`,
digest `sha256:f36940bd…`, created 2026-08-12, revision `c5dd87e`. The same tag
the 09-18 record ran.

**Launch path.** Not a shadowed quadlet. The shipped launcher takes no
`--kv-cache-dtype` or `--kv-cache-memory` knob — `/usr/share/kinoite/vllm/vllm-serve.sh`
exposes ten environment variables and its final `exec vllm serve` never expands
`"$@"`, so trailing arguments are dropped — and `vllm.container` reinstalls the
host copy of that launcher from `/usr` on every start. So the arms ran a patched
copy of the baked launcher under `~/bench/vllm-kvarm/bin/`, mounted at
`/opt/kinoite-arm`, started by a `prodab.sh` derivative that reproduces the
quadlet's devices, groups, `--ipc=host`, seccomp, HF-cache mount and
`/opt/vllm-cache` compile-cache mount. The shipped quadlet and launcher were
never modified and `~/.config/containers/systemd/users/` stayed empty throughout.

The patch against `/usr/share/kinoite/vllm/vllm-serve.sh` is two lines, after
`--max-num-batched-tokens`:

```bash
    ${VLLM_KV_CACHE_DTYPE:+--kv-cache-dtype "$VLLM_KV_CACHE_DTYPE"} \
    ${VLLM_KV_CACHE_MEMORY:+--kv-cache-memory "$VLLM_KV_CACHE_MEMORY"} \
```

With both unset the launcher is behaviourally the shipped one. `prodab.sh` is a
validated stand-in for the quadlet path: the 09-15 run used it as its production
control and reproduced the 09-13 triton record to within ±0.34 ms/pass.

**Otherwise the 09-18 arm.** `Qwen/Qwen3.8-27B-FP8`, TP=2, MTP k=4 on
`TRITON_ATTN`, prefix caching with `mamba-cache-mode align`,
`--max-num-batched-tokens` 8192, `NCCL_PROTO=Simple`. Speculation was on in every
arm (`method='mtp'`, `num_spec_tokens=4`), so all four columns below are
speculating arms.

**Three arms.**

| arm | `--kv-cache-dtype` | util | `--max-model-len` | `--kv-cache-memory` |
|---|---|---|---|---|
| a1-profile | fp8 | 0.98 | 262,144 | profiled |
| a1-pinned | fp8 | 0.98 | 262,144 | 11,077,064,253 |
| a2 | fp8 | 0.80 | 131,072 | profiled |

a2 is the one-variable ablation: it is the 09-18 configuration with
`--kv-cache-dtype fp8` added and nothing else changed.

**The pin was derived, not guessed.** a1-profile ran with `--kv-cache-memory`
unset, which is always safe and fills the compile cache; a1-pinned then pinned its
profiled 9.76 GiB scaled by 1.057, radiance's measured reclaim over its own
profiler. That first factor started, so no backoff was needed and no lower value
was tested.

**Pool figures are parsed, not transcribed.** `kvparse.py` reads them from the
server's own lines and was validated first against the two existing logs, where it
reproduces 943,581 tokens / 3.60x / 17.29 GiB / fp8 for radiance and 7.94 GiB /
218,941 tokens / 1.67x / auto for production.

## Numbers

Decode versus depth, 512 tokens generated, 3 reps, medians, `acc` is mean accepted
length. Spread was under 0.1% at every point in every arm.

| depth | a1-profile | a1-pinned | a2 | 09-18 record |
|---|---|---|---|---|
| | tok/s · ms/pass · acc | tok/s · ms/pass · acc | tok/s · ms/pass · acc | tok/s · ms/pass · acc |
| rust (28 tok) | 52.54 · 61.95 · 3.255 | 51.45 · 62.20 · 3.200 | 49.33 · 62.27 · 3.072 | 54.59 · 59.36 · 3.241 |
| python (32 tok) | 56.77 · 62.32 · 3.538 | 57.13 · 62.36 · 3.562 | 58.34 · 62.24 · 3.631 | 61.13 · 59.52 · 3.638 |
| prose (31 tok) | 47.28 · 62.60 · 2.960 | 48.67 · 62.25 · 3.030 | 46.97 · 62.28 · 2.926 | 53.13 · 59.49 · 3.160 |
| control mean | 52.20 · — · 3.251 | 52.42 · — · 3.264 | 51.55 · — · 3.210 | 56.28 · — · 3.346 |
| 189 | 63.14 · 63.23 · 3.992 | 59.43 · 63.59 · 3.779 | 59.39 · 63.39 · 3.765 | 62.28 · 59.81 · 3.725 |
| 9,479 | 27.72 · 135.55 · 3.757 | 27.55 · 135.93 · 3.745 | 27.97 · 135.35 · 3.785 | 57.39 · 67.59 · 3.879 |
| 37,763 | 10.42 · 356.78 · 3.717 | 11.25 · 354.98 · 3.992 | 9.80 · 356.26 · 3.490 | 43.79 · 92.24 · 4.039 |
| 69,751 | 6.18 · 603.92 · 3.730 | 5.92 · 603.16 · 3.573 | 6.78 · 605.63 · 4.104 | 31.55 · 120.21 · 3.793 |

Slope in ms per target pass per 1K of context, 189 → 69,751 tokens:

| arm | slope | arithmetic |
|---|---|---|
| a1-profile | 7.773 | (603.92 − 63.23) / 69.562 |
| a1-pinned | 7.757 | (603.16 − 63.59) / 69.562 |
| a2 | 7.795 | (605.63 − 63.39) / 69.562 |
| 09-18, bf16 KV | 0.868 | (120.21 − 59.81) / 69.562 |
| radiance 09-15, fp8 KV on R4D | 0.052 | (26.10 − 22.46) / 69.562 |

Memory and pool:

| | a1-profile | a1-pinned | a2 | 09-18 |
|---|---|---|---|---|
| KV memory | 9.76 GiB profiled | 10.32 GiB pinned | 4.02 GiB profiled | 6.31 GiB profiled |
| pool | 538,771 tok | 569,185 tok | 200,540 tok | 174,274 tok |
| MiB/token | 0.01855 | 0.01857 | 0.02053 | 0.03708 |
| max concurrency | 2.06x @ 262,144 | 2.17x @ 262,144 | 1.53x @ 131,072 | 1.33x @ 131,072 |
| 262,144 admitted | yes | yes | n/a (len 131,072) | no |
| padding-layer waste | 6.25% | 6.25% | 6.25% | — |
| launch to healthy | 120 s | 70 s | 110 s | ~80 s (second start) |
| peak VRAM per card | 28,408 MiB | 28,984 MiB | 22,530 MiB | — |
| host MemAvailable min | 48,380 MiB | 49,404 MiB | 48,480 MiB | — |

Run-wide acceptance from the spec_decode counters, as `1 + accepted/drafts`:
3.470 (a1-profile, 11,098/4,494), 3.446 (a1-pinned, 11,072/4,526), 3.453 (a2,
11,077/4,514).

## What it means

**fp8 KV halves KV density, exactly.** 0.01855 MiB/token against the 09-18
record's 0.03708 is a ratio of 1.999. The 09-18 pool was not small because of
utilisation or weights; it was bf16 KV. At fp8 density a 262,144-token pool needs
4.75 GiB, less than the 6.31 GiB that `gpu_memory_utilization` 0.80 already
yielded on 09-18.

**The 09-18 context verdict does not stand.** 262,144 is admitted, and the pool
holds 2.06 of them profiled and 2.17 pinned. The claim in that record — that "vLLM
would refuse them outright" at the depths this box runs — was an artefact of the
default KV dtype, not a property of vLLM on this hardware.

**The slope is set by the KV dtype and by nothing else in the memory config.**
Three arms at three different utilisations, context lengths and pin states give
7.773, 7.757 and 7.795 ms/1K — a spread of 0.5%. a2 differs from the 09-18
configuration only in `--kv-cache-dtype fp8` and carries the whole effect, so
utilisation and `max_model_len` contribute nothing to it.

**That slope is 9.0x worse than bf16 KV, not better.** 7.795 against 0.868. The
pre-registered expectation was ~0.44 if fp8 KV explained half the gap to radiance,
or ~0.88 if it explained none. The measured answer is off that scale in the wrong
direction: at 69,751 tokens fp8 KV costs 5.0x the decode of bf16 KV (6.78 against
31.55 tok/s).

**It is not a speculation effect.** Mean accepted length at 69,751 is 3.730 /
3.573 / 4.104 against the record's 3.793, and run-wide acceptance is 3.45–3.47.
The cost is in the target forward pass.

**So radiance's flat slope is achieved despite fp8 KV, not because of it.**
Radiance runs the same `--kv-cache-dtype fp8` at 0.052 ms/1K on `--attention-backend R4D`.
Since fp8 KV costs 7.8 ms/1K on `TRITON_ATTN` and 09-18's bf16 KV on the same
backend costs 0.868, the flat slope belongs to R4D, not to the KV dtype. The
mechanism was not measured here; a backend that pays dequantisation per access on
a path R4D implements natively is consistent with the numbers but is not
established by them.

**fp8 KV is not adoptable on the shipped launcher on this evidence.** It buys the
262,144 ceiling and costs 5x decode at the depth this box actually runs. Neither
half is worth the other.

**An explicit pin is free, and radiance's reclaim factor transfers.** Pinning
9.76 × 1.057 GiB yielded 569,185 tokens against 538,771 profiled, +5.65% — within
0.05 points of the 5.7% recorded for radiance, on a different image and a
different attention backend. Its depth series is inside a1-profile's noise at
every point, so the pool came for free. That 1.057 is now measured twice rather
than borrowed once.

**The two-start cold-compile pattern did not recur.** All three arms came up on
one start, at 120 s, 70 s and 110 s. a2 is the interesting case: it profiled
**4.02 GiB**, which is exactly the figure the 09-18 first start died on, needing
4.74 GiB against it. At fp8 density 131,072 tokens needs about 2.6 GiB, so the
same cold-compile shortfall was survivable. One occurrence, on one config; not a
general claim that fp8 KV removes the pattern.

**Density is not constant across `max_model_len`.** a2 measured 0.02053
MiB/token against a1's 0.01855, about 11% higher at half the context length, with
the same 6.25% padding-layer waste logged in both. Block granularity is the
obvious suspect. Not investigated.

Nothing is adopted. The shipped quadlet, launcher and `gpu_memory_utilization`
0.80 are unchanged; no shadow unit was created.

Not measured:

- **whether the slope collapse is specific to `TRITON_ATTN`.** This is the next
  arm, and the one that would decide whether fp8 KV is usable on production vLLM
  at all: run a2 again against a different attention backend. Nothing here
  separates "fp8 KV is slow" from "fp8 KV is slow on this backend"
- output quality under fp8 KV at any depth. Only one sanity prompt per arm, which
  every arm answered coherently
- a2's pool at a warm profile. Its 4.02 GiB is a cold-compile figure and is not
  comparable to the 09-18 record's warm 6.31 GiB as a pool measurement
- whether 262,144 is admitted at the shipped `gpu_memory_utilization` 0.80. The
  arithmetic says yes with room (6.31 GiB against 4.75 needed), but the arm that
  would show it ran at `max_model_len` 131,072
- concurrency, agentic replay, TTFT and prefill under fp8 KV
- repeats of a2. a1 was run twice at near-identical config and reproduced itself
  within 0.5%; a2 ran once
- the bf16 control was not re-measured. The 09-18 record is quoted, on the same
  image and tag, three weeks earlier
