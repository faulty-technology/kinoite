---
date: 2026-09-13
subject: R9V Qwen3.8 Flash Next (177B MoE IQ4_XS, patched vLLM TP2 MTP2) against lemonade's Qwen3.8-27B Q8_K_XL, decode versus depth and agentic replay
harness: ~/bench/r9v/armA.sh, armb.sh, agentic.sh driving ~/bench/depth.py, ~/bench/agentic.py, /usr/share/kinoite/vllm/bench.py and ~/bench/r9v/warmup.py; raw output ~/bench/r9v/{armA,armb,agentic,sampler}.log and serve.log.gz (off-repo, on the box)
box: kinoite-north
---

# R9V Qwen3.8 Flash Next against the 27B daily driver

## What was measured

kyuz0/amd-r9700-ai-toolboxes `ea6a9b1` (2026-09-12) claims 73–85 decode tok/s on
2× R9700 + 64 GB for its R9V toolbox. R9V (Dyluhn/R9V `9fccc00`) is vLLM
0.26.1rc0 with gfx1201 kernels, serving `Dyluhn/Qwen3.8-Flash-Next-R9V-IQ4_XS`
at `bf836f0`: a 177B MoE, IQ4_XS GGUF, FP8 MTP at depth 2, TP=2, one sequence,
131,072 context. It was started through upstream's `toolboxes/r9v/run.sh` with
`config.env.example` unchanged except for the image, the paths and host port 8000.

The published image `docker.io/kyuz0/amd-r9700-toolboxes:r9v-rocm-10.0` (digest
`sha256:8c1a3d80…`, built 2026-09-12 16:07Z from `f90455a`) fails upstream's own
identity probe with `Torch and Python amdsmi load separate AMD SMI libraries`.
The fix landed after it, in `e8481d6`. The server ran from a local layer on top
of the published image that applies `e8481d6`'s symlink loop and probe. With
that layer the probe finds both R9700s.

Two arms ran sequentially the same afternoon, with thinking off and temperature 0.
Every harness times decode from the first content token to the last.

- **A, R9V.** kyuz0's warmup shape: one 63,766-token request, then eight short
  ones. Then `bench.py 256` twice, `depth.py - 512 3 8000`, one 127,760-token
  request, and `agentic.py 8000 /v1 48 8 256 2`.
- **B, 27B.** Lemonade's shipped llama.cpp b1328 (rocm-nightly),
  Qwen3.8-27B-UD-Q8_K_XL (snapshot `4ca7207`), `-sm tensor -fa on`, Q4_0 MTP
  draft at `--spec-draft-n-max 4`, `-c 98304 -np 1`, via `~/bench/depth.sh`. This
  is the Q8_K_XL tensor arm of
  [runs/2026-08-30-quant-sweep](2026-08-30-quant-sweep.md) verbatim, and the
  recipe behind `user.Qwen3.8-27B-Q8XL`, which has 129 loads in the lemonade journal.

The agentic replay was run on R9V only. Its comparison columns are the figures
recorded in [runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md),
which used the same harness and the same prompt bytes. They were not re-measured.

## Numbers

Decode versus depth (`depth.py`, 512 tokens, 3 reps). tok/s is bracketed by
min–max; acc is mean accepted length.

| depth | R9V tok/s | R9V ms/pass | R9V acc | 27B tok/s | 27B ms/pass | 27B acc | R9V / 27B |
|---|---|---|---|---|---|---|---|
| control mean | 82.58 | 27.85–31.30 | 2.483 | 65.48 | 49.13–49.41 | 3.223 | 1.26x |
| 189 | 77.36 | 36.44 | 2.819 | 76.49 | 49.55 | 3.790 | 1.01x |
| 9,479 | 77.23 | 33.53 | 2.590 | 69.79 | 51.16 | 3.570 | 1.11x |
| 37,763 | 77.05 | 32.62 | 2.513 | 61.93 | 57.16 | 3.540 | 1.24x |
| 69,751 | 79.19 | 33.87 | 2.682 | 56.24 | 63.48 | 3.570 | 1.41x |

R9V control per workload: rust 81.98, python 84.59, prose 81.18. 27B: rust
66.97, python 72.20, prose 57.28.

R9V single requests (`warmup.py`, 256 tokens):

| prompt tokens | TTFT | decode tok/s | cache |
|---|---|---|---|
| 63,766 | 32.818 s | 82.09 | cold, first sight of the prompt |
| 127,760 | 35.217 s | 82.93 | assisted, see below |
| 40–44, eight requests | 0.178–0.227 s (first: 1.470 s, JIT) | 80.48–88.94 | — |

kyuz0's panel shape (`bench.py 256`):

| run | rust | python | prose | mean | acceptance length |
|---|---|---|---|---|---|
| 1 | 86.08 | 88.96 | 81.53 | 85.52 | 2.403 |
| 2 | 85.85 | 88.94 | 81.55 | 85.45 | 2.403 |

Agentic replay (`agentic.py`, 8 turns, 2 reps, 233,962 prompt tokens presented in
every arm):

| metric | R9V | lemonade Q8XL (08-31) | vLLM FP8 prefix caching on (08-31) |
|---|---|---|---|
| TTFT turn 1, mean of reps | 3.536 s | 5.992 s | 2.652 s |
| TTFT turns 2+, mean | 1.369 s | 0.980 s | 0.441 s |
| decode median | 81.11 t/s | 67.66 t/s | 48.04 t/s |
| wall median per turn | 3.246 s | 4.724 s | 5.805 s |
| generated tokens | **2,655** | 4,096 | 4,096 |
| end-to-end | 41.18 tok/s over 64.5 s | 48.37 tok/s over 84.7 s | 41.63 tok/s over 98.4 s |

The wall and end-to-end rows are not equal-work comparisons. R9V ended 8 of 16
turns before the 256-token cap (72–88 tokens); every 08-31 arm reached it on
every turn. Fewer generated tokens shorten wall time and lower end-to-end tok/s.

R9V's per-turn TTFT:

- Rep 1, turn 1 (cold, 13,042 tokens): 6.115 s.
- Rep 1, turn 2: 6.321 s. It did not reuse turn 1's prefix; the cause was not
  examined.
- Rep 2, turn 1: 0.956 s, reusing rep 1's cache.
- Warm turns otherwise: 0.918–1.727 s.

Arm B reproduces its record. The control mean is 65.48 against 65.91, and
ms/pass is within 0.4% at every depth (49.55 / 51.16 / 57.16 / 63.48 against
49.66 / 51.16 / 56.97 / 63.23). An earlier arm-B run overlapped the 90 GiB model
download. It came out at +1.87 to +2.37 ms/pass at every point, with a control
mean of 63.17, and was discarded.

R9V memory, from the serve log and a 2 s sampler:

| | TP0 | TP1 | total |
|---|---|---|---|
| hot experts, VRAM | 17.810 GiB | 19.975 GiB | 37.785 GiB |
| cold experts, host RAM (UVA) | 9.906 GiB | 7.741 GiB | 17.647 GiB |
| dynamic expert cache | 0 | 0.866 GiB, 16 slots | 0.866 GiB |
| KV reserved | 2.13 GiB | 2.13 GiB | 133,719 tokens |
| peak VRAM | 28,723 MiB | 31,720 MiB | |

- **Host RAM.** North has 59.95 GiB. MemAvailable bottomed at 16,627 MiB during
  the serialized expert load, and the load pushed 3.6 GiB into zram swap
  (1.2 GiB compressed). About 24.2 GiB was available while serving.
- **Startup.** 472 s to `/health` on the first start, compile included.
- **Pinned memory.** Cold experts go through vLLM's UVA offloader. North's 8 MB
  memlock limit produced no warnings.
- **Prefix caching** is on by the engine's default (`enable_prefix_caching=True`,
  `mamba_cache_mode=align` set automatically). Neither `r9v-serve` nor the
  profile sets it. Across arm A's decode runs, before the agentic replay, 406,400
  of 662,076 prompt tokens (61.4%) hit the cache, so `depth.py` reps 2–3 are
  cache-assisted.
- **The 127,760-token request.** It started with the KV pool 57% full (the
  retained blocks of the 69,751-token prompt, which shares its filler prefix)
  and finished at 93%. Its TTFT is not a cold prefill figure.
- **MTP.** Over the same decode runs: 13,007 of 17,178 draft tokens accepted, a
  mean accepted length of 2.51.

## What it means

**kyuz0's figure reproduces on a 59.95 GiB host.** The panel mean is 85.5
against his 72.7–85.5 panel range, and his placement totals match to the
hundredth of a GiB.

**R9V decode is flat in depth; the 27B's is not.** R9V's ms/pass is 36.44 at 189
tokens and 33.87 at 69,751. The 27B's grows about 0.20 ms per 1K tokens, from
49.55 to 63.48, so the two are level at short depth and R9V leads 1.41x by 70K.
A single 127,760-token request still decoded at 82.93. The gap is entirely pass
cost: R9V accepts fewer tokens per pass (2.26–2.82 against 2.83–3.79) and spends
27.85–36.44 ms on each, where the 27B spends 49.13–63.48 ms.

**Why it is flat is not established.** The first request JIT-compiled sparse
"QSA" attention kernels. That this attention reads a bounded subset of the KV is
a reading of the kernel names, not a measurement.

**In the agentic replay, R9V decodes faster and re-prefills slower.** Decode
median is 1.20x lemonade's 08-31 figure (81.11 against 67.66). Warm-turn TTFT is
1.40x lemonade's (1.369 s against 0.980 s) and 3.10x vLLM's with caching on.
Cold prefill is the other cost: 63,766 tokens took 32.8 s to the first token,
about 1,940 tok/s. How wall time and end-to-end compare is not settled by this
run, because R9V generated 35% fewer tokens.

Not measured:

- output quality of the 177B MoE at IQ4_XS against the 27B at Q8_K_XL
- tool-call correctness
- why R9V stopped early on 8 of 16 agentic turns, and why rep 1 turn 2 missed
  the prefix cache
- more than one concurrent request (the profile is one sequence)
- a cold prefill at 128K (kyuz0 reports 67.4 s for 129,935 tokens)
- whether the profile survives days of mixed use on 59.95 GiB
