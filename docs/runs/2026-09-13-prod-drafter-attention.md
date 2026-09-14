---
date: 2026-09-13
subject: Production vLLM (shipped image and launcher) with the MTP drafter on its default attention backend or on TRITON_ATTN, Qwen3.8-27B-FP8 decode versus depth
harness: ~/bench/prodab/prodab-all.sh (orchestration, one retry on a cold-compile KV-memory failure; not needed) and prodab.sh (one arm), driving ~/bench/depth.py; raw output ~/bench/prodab/prodab.log, serve-{base,triton}.log, sanity-*.txt, sampler-*.log (off-repo, on the box)
box: kinoite-north
---

# MTP drafter attention backend on production vLLM

## What was measured

In R9V's vLLM fork, moving the MTP drafter from ROCM_ATTN to TRITON_ATTN cut
7.60 ms per pass on the control and 70.58 ms at 69,751 tokens
([runs/2026-09-13-r9v-drafter-kv-layout](2026-09-13-r9v-drafter-kv-layout.md)).
Production vLLM's 09-04 log shows the same ROCM_ATTN override line. This run asks
whether production pays the same cost.

**Image.** The shipped `docker.io/kyuz0/vllm-therock-gfx1201:latest`: vLLM
`0.22.1rc1.dev499+g470229c37`, torch `2.13.0a0+rocm7.14.0a20260608`, HIP 7.14,
Triton 3.7.0.

**Launch.** The shipped `vllm-serve.sh`, identical to `/usr/share/kinoite/vllm/`,
was started directly rather than through the pod, so Open WebUI never ran. The
container got the `vllm.container` quadlet's devices, `--ipc=host`,
`seccomp=unconfined`, `video` and `render` groups, `:z` mounts for the model cache,
the launcher directory and the warm compile cache, and `VLLM_MODEL=Qwen/Qwen3.8-27B-FP8`.
It published 127.0.0.1:8000.

**The launcher's own flags:**

- TP=2, `--max-num-seqs 4`, `--max-model-len 131072`,
  `--gpu-memory-utilization 0.80`, `--max-num-batched-tokens 8192`;
- `--attention-backend TRITON_ATTN`;
- prefix caching with `mamba-cache-mode align`;
- `NCCL_PROTO=Simple`.

**The one variable is `VLLM_SPECULATIVE`:**

| arm | VLLM_SPECULATIVE |
|---|---|
| base | unset; the launcher default `{"method":"mtp","num_speculative_tokens":4}` |
| triton | `{"method":"mtp","num_speculative_tokens":4,"attention_backend":"TRITON_ATTN"}` |

**Per arm.** One greedy sanity prompt, `bench.py 128` as a warm-up, then
`depth.py - 512 3 8000`. Thinking off, temperature 0, decode timed from the first
content token to the last. The base arm ran first, then the triton arm.

Both arms were healthy after 100 s on the warm compile cache, and neither needed
the retry.

**The override took effect.** The triton arm's launch arguments show
`'speculative_config': {'method': 'mtp', 'num_speculative_tokens': 4, 'attention_backend': 'TRITON_ATTN'}`,
and neither of the two `Overriding with ROCM_ATTN` lines the base arm logged
appears. Both arms put the target model on TRITON_ATTN via `--attention-backend`.

## Numbers

Decode versus depth (`depth.py`, 512 tokens, 3 reps). acc is mean accepted
length; the decode tok/s min–max spread is under 0.2% at every point in both arms.

| point | base tok/s | base ms/pass | base acc | triton tok/s | triton ms/pass | triton acc | Δ ms/pass |
|---|---|---|---|---|---|---|---|
| rust (28 tok) | 49.53 | 58.96 | 2.920 | 49.35 | 59.17 | 2.920 | +0.21 |
| python (32 tok) | 60.14 | 59.01 | 3.549 | 59.56 | 59.17 | 3.524 | +0.16 |
| prose (31 tok) | 53.78 | 59.13 | 3.180 | 52.99 | 59.28 | 3.141 | +0.15 |
| control mean | 54.48 | — | 3.216 | 53.97 | — | 3.195 | +0.17 (+0.3%) |
| 189 | 66.34 | 59.72 | 3.962 | 65.82 | 59.73 | 3.931 | +0.01 |
| 9,479 | 51.97 | 73.38 | 3.813 | 55.28 | 67.47 | 3.730 | −5.91 (−8.1%) |
| 37,763 | 33.78 | 115.72 | 3.908 | 42.55 | 91.86 | 3.908 | −23.86 (−20.6%) |
| 69,751 | 20.82 | 164.94 | 3.433 | 28.68 | 120.50 | 3.456 | −44.44 (−26.9%) |
| slope, 189 → 69,751 tokens | | 1.51 ms per 1K | | | 0.87 ms per 1K | | −42.2% |

Decode tok/s change, base to triton: −0.9% on the control, −0.8% at 189, +6.4% at
9,479, +26.0% at 37,763, +37.8% at 69,751.

The base arm reproduces production's record: against the prefix-caching-on arm of
[runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md), ms/pass differs by
−1.04, −1.64, −1.57 and −0.51 at 189, 9,479, 37,763 and 69,751 tokens.

KV and memory:

| | base | triton |
|---|---|---|
| attention block size / mamba page padding | 816 tokens / 1.62% | 816 tokens / 1.62% |
| available KV memory after profiling | 7.86 GiB | 6.81 GiB |
| GPU KV cache size | 216,744 tokens | 188,187 tokens (−13.2%) |
| concurrency at 131,072 tokens per request | 1.65x | 1.44x |
| host MemAvailable minimum | 49,329 MiB | 45,727 MiB |

This vLLM logs no profiling breakdown, so what took the extra 1.05 GiB is not
shown.

Speculative counters at the end of each arm, sanity prompt and warm-up included:

| arm | drafts | accepted / draft tokens |
|---|---|---|
| base | 4,529 | 11,057 / 18,116 |
| triton | 4,558 | 11,031 / 18,232 |

The sanity output was byte-identical across the two arms.

## What it means

**Production pays the drafter cost, and it grows with depth.** Moving the drafter
to TRITON_ATTN leaves short prompts unchanged: +0.17 ms per pass on the control,
+0.01 at 189 tokens. At 69,751 tokens it cuts 44.44 ms per pass (−26.9%), and
the per-1K-token slope falls from 1.51 to 0.87 ms (−42.2%). Decode rises from
20.82 to 28.68 tok/s at 69,751 tokens (+37.8%) and from 33.78 to 42.55 at 37,763
(+26.0%).

**The shape differs from R9V's fork.** There the same change also cut 7.60 ms at
short depth. Here the fixed per-pass cost is untouched, and the whole gain sits in
the depth term. Why ROCM_ATTN's drafter cost grows with context in this vLLM is
not established. This vLLM predates the layout-resolution code, so the R9V
fallback-path reading does not carry over.

**Output is unchanged on the evidence here.** The sanity output is byte-identical,
and mean accepted length stays within 0.04 at every point except 9,479 tokens (3.813 against 3.730).

**The cost is KV capacity.** The pool holds 13.2% fewer tokens, which is still
1.44x one full 131,072-token request.

Not measured:

- more than one concurrent stream (the launcher allows 4), including what the
  smaller pool does there
- tool-call correctness, or output quality beyond one sanity prompt
- the agentic replay, prefill and TTFT with the Triton drafter
- repeats: one run per arm, though every point's spread is under 0.2%
