---
date: 2026-09-13
subject: R9V fused GDN+MTP HIP kernel on and off, Qwen3.8-27B-FP8 in the R9V vLLM image, decode versus depth
harness: ~/bench/r9v/gdnab/gdnab.sh (one arm), gdnab-all.sh and gdnab-arms.sh (orchestration), patch-wrapper.py (call logger), driving ~/bench/depth.py; raw output ~/bench/r9v/gdnab/{gdnab,gdnab2}.log, serve-*.log, sanity-*.txt, sampler-*.log (off-repo, on the box)
box: kinoite-north
---

# Fused GDN+MTP kernel on the FP8 27B

## What was measured

R9V ships `fused_gdn_mtp_hip` (Dyluhn/r9v-gfx1201-kernels `7905d9e`), a
speculative-decode Gated DeltaNet core written for Qwen3.8 Flash Next at TP=2
([runs/2026-09-13-r9v-flash-next](2026-09-13-r9v-flash-next.md)).

**Gate.** The wrapper's `core_supported()` checks:

- TP=2;
- 8 key and 24 value heads per rank;
- key and value head dims of 128;
- a float32 recurrent state.

The call site also requires a batch made only of speculative decodes, with at
most 8 tokens per request (`MAX_FUSED_GDN_MTP_TOKENS`).

**Why the 27B qualifies.** Qwen3.8-27B's GDN layers (48 of 64) have exactly that
geometry, and MTP k=4 puts 5 tokens per request, inside the cap. FP8 weights
never reach the kernel, which starts after the projections.

**Image.** The kernel exists only in R9V's vLLM fork, so both arms ran in
`localhost/r9v-rocm-10.0:amdsmi`: vLLM `0.26.1rc0+r9v.g4b20917386dc`, torch
`2.11.0+rocm10.0.0`, HIP 7.15, Triton 3.8.0.

**Flags.** `Qwen/Qwen3.8-27B-FP8` was served from the shared cache with the
shipped `vllm-serve.sh` flags: TP=2, MTP k=4, prefix caching with
`mamba-cache-mode align`, `--attention-backend TRITON_ATTN`,
`--max-model-len 131072`, `--max-num-seqs 4`, `--gpu-memory-utilization 0.80`,
`--max-num-batched-tokens 8192` and `NCCL_PROTO=Simple`. Both arms added
`--mamba-ssm-cache-dtype float32`, which the kernel requires.

**The variable.** `QWEN38_USE_HIP_FUSED_GDN_MTP`, 1 or 0. Upstream's
`kernel enabled` line prints whenever it is 1, so it proves nothing. Both arms
bind-mounted the same copy of `fused_gdn_mtp_hip.py`, patched to log a warning on
the first real `run()` or `run_core()` call per worker process. `gdnab.sh` has
since gained layout and drafter-backend options; with them unset it runs this
configuration.

**Per arm.** A fresh container, one greedy sanity prompt, `bench.py 128` as a
warm-up, then `depth.py - 512 3 8000`. Thinking off, temperature 0, decode timed
from the first content token to the last.

**Order.** Kernel on (the first start of this model in this image), kernel off,
kernel on again.

## Numbers

Decode versus depth. tok/s is bracketed where its min–max spread exceeds 2%;
acc is mean accepted length.

| point | off tok/s | off ms/pass | off acc | on tok/s | on ms/pass | on acc | Δ ms/pass |
|---|---|---|---|---|---|---|---|
| rust (28 tok) | 46.70 | 64.49 | 3.012 | 48.72 | 61.82 | 3.012 | −2.67 |
| python (32 tok) | 54.88 | 64.72 | 3.552 | 58.24 | 61.47 | 3.580 | −3.25 |
| prose (31 tok) | 43.73 | 64.46 | 2.819 | 49.91 | 61.55 | 3.072 | −2.91 |
| control mean | 48.43 | — | 3.127 | 52.29 | — | 3.221 | — |
| 189 | 61.18 | 65.13 | 3.984 | 62.53 | 61.91 | 3.871 | −3.22 |
| 9,479 | 36.07 | 101.38 | 3.657 | 39.91 | 98.49 | 3.931 | −2.89 |
| 37,763 | 16.10 [16.10–17.63] | 217.91 | 3.508 | 18.95 [17.72–18.95] | 204.71 | 3.879 | −13.20 |
| 69,751 | 10.69 [10.69–11.16] | 342.59 | 3.662 | 10.50 [10.49–11.18] | 342.71 | 3.597 | +0.12 |

The on column is the second on start; the first on start never served.

Kernel evidence:

- **On arm.** First-call lines for `run_core` from both workers (pids 188 and
  226), and `Qwen3.8 TP2 fused speculative GDN HIP kernel enabled`.
- **Off arm.** No call lines and no enabled line.
- **Both arms.** `Falling back to the Triton GDN decode path:
  torch.ops._C.fused_gdn_decode_post_conv_mtp is not built`. That line concerns a
  separate stock op.

Speculative counters at the end of each arm, sanity prompt and warm-up included:

| arm | drafts | accepted / draft tokens |
|---|---|---|
| off | 4,624 | 10,990 / 18,496 |
| on | 4,499 | 11,108 / 17,996 |

Memory:

| | on, first start | off | on, second start |
|---|---|---|---|
| available KV memory | 3.8 GiB | 6.31 GiB | 6.31 GiB |
| KV pool | start failed | 175,614 tokens | 175,701 tokens |
| weights + non-torch / peak activation / CUDA graphs | not reached | 17.56 / 1.62 / 0.92 GiB | 17.56 / 1.61 / 0.91 GiB |
| host MemAvailable minimum | — | 49,778 MiB | 49,646 MiB |

The first on start compiled cold (Dynamo transform 8.03 s). It then failed vLLM's
check that one 131,072-token request fits: 4.71 GiB needed, 3.8 GiB available.
The same flags passed on the second start, with the compile cache the off arm had
filled. The shortfall came from the cold compile, not the kernel.

Both arms answered the sanity prompt coherently. The texts diverge within the
first sentence ("which ones to evict" against "which items to discard").

Attention setup, the same in both arms, from the serve logs:

- attention blocks of 816 tokens;
- the target model on TRITON_ATTN;
- the MTP drafter on ROCM_ATTN, logged as an override after `Loading drafter
  model`. Its declared layouts `(LHBNC, LBHNC)` resolve the KV cache to `LBHNC`.

The R9V image's depth cost next to production vLLM:

| depth | this run, kernel off, ms/pass | production vLLM, prefix caching on ([runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md)) |
|---|---|---|
| 189 | 65.13 | 60.76 |
| 9,479 | 101.38 | 75.02 |
| 37,763 | 217.91 | 117.29 |
| 69,751 | 342.59 | 165.45 |

This is not a controlled comparison. It is a different image on a different day,
and the production figures come from a different stack: vLLM
`0.22.1rc1.dev499+g470229c37`, torch 2.13 nightly on ROCm 7.14, Triton 3.7.0.
That vLLM predates the layout-resolution code and logs no layout.

## What it means

**The kernel runs on the 27B and saves a fixed ~3 ms per pass.** It was selected
and ran on both workers, with no change beyond the env var and the float32 state
flag. The five points with a min–max spread under 2% show a cut of 2.67–3.25 ms
per target forward pass. On the control that averages 2.94 ms (−4.6%).

**It cannot change the depth slope.** GDN state is constant-size, and the growth
comes from the 16 full-attention layers. At 69,751 tokens the difference is
+0.12 ms. The 37,763 point moved 13.20 ms, but that is not a reliable reading:
both arms' spread there is 7–10%, and acceptance differed (3.508 against 3.879).

**In this image it does not pay.** From 189 to 69,751 tokens, the fork's vLLM
spends 3.99 ms per 1K tokens of context, against 1.50 for production in the 08-31
run. At 70K that is 342.59 ms/pass against 165.45, which a 3 ms saving does not
offset. Why the slope is steeper is not established by this run.

Not measured:

- the kernel on a stack whose depth cost matches production's (it exists only in
  R9V's vLLM)
- real-weight parity against the Triton GDN path; the only output check was one
  sanity prompt
- more than one concurrent request, although the call-site gate already excludes
  mixed prefill and decode batches
- repeats: one run per arm, and the 37,763 and 69,751 points need more reps
