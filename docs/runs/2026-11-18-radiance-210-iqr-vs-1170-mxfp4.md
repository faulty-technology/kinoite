---
type: Run
date: 2026-11-18
subject: "radiance 2.1.0 IQ4R-L-V4 and IQ8R-dflash against 1.17.0 MXFP4, same night"
harness: "~/bench/radeng/ (off-repo, on the box), the 11-07 harness unchanged: run-client.sh, radeng-bench.py, gsm8k-deep.py. night21.sh drives the three arms in turn under inh-run.sh; the two 2.1.0 arms are ad-hoc podman containers with the draft unit's flags, configs in cfg21/bench-{iq4,iq8}.yaml. Raw: bench-{Q4-21,Q8-21,M1170b}.jsonl, gsm8k-{Q4-21,Q8-21,M1170b}.jsonl, serve-*.log, stats-*.json, metrics-post-*.txt, night21.log"
box: kinoite-north
---

# radiance 2.1.0 IQ4R-L-V4 and IQ8R-dflash against 1.17.0 MXFP4, same night

## What was measured

Three arms, one after the other, on 2026-11-17 23:39 to 2026-11-18 01:21 EST,
at a **235 W** cap per card (read back from `power1_cap` in every arm). Every
bench request sets temperature 0 and thinking off.

radiance 2.0.0 dropped MXFP4 and FP8 as whole-model formats and refuses those
containers, so 2.1.0 cannot run the shipped file. The 2.1.0 arms therefore
change the engine and the weights together.

- **Q4-21**: radiance 2.1.0, image `sha256:c9affc48…`.
  `StillDeadcode/qwen3.8-27b-iqr-v4` file `qwen3.8-27b-iq4r-l-v4.rad` at
  revision `e5f1b3e`, sha256 `d57d1428…`, 17.4 GiB. IQR-V4 trellis trunk, about
  4.8 bits a weight. Its DFlash2 drafter is MXFP4 (31 tensors,
  `fp4_e2m1*e8m0[1x32]`, 877 MiB per `rad-info`), and 2.1.0 serves it.
- **Q8-21**: radiance 2.1.0, same image.
  `StillDeadcode/qwen3.8-27b-iq8r-dflash` at revision `c127a34`, sha256
  `9388f4c0…`, 28.8 GiB. Rotated int8 trunk with an int8/codebook DFlash2
  drafter.
- **M1170b**: radiance 1.17.0 through `radiance.service` as deployed, the
  MXFP4 `.rad` (`a4908940…`). This is a same-night control for M1170 in
  [runs/2026-11-07-radiance-1170-fp8-vs-mxfp4](2026-11-07-radiance-1170-fp8-vs-mxfp4.md).

The 2.1.0 configs are the drafted unit's settings (`tp: 2`, `max-num-seqs: 8`,
`kv-cache-dtype: i8`, `checkpoint-slots` at auto, the same sampling and
reasoning defaults) with the window raised to 262,144 and `prefix-cache-mib`
to 8448, so that every radeng-bench section runs. M1170b ran
`--kv-cache-dtype fp8 --prefix-cache-mib 8192` at the same window. The
speculation depth was each container's own: 7 for both DFlash2 drafters.

## Numbers

**The control matches 11-07.** M1170b answered GSM8K identically to M1170:
480/500, 100% agreement, 9 truncated, 335 tokens an answer, a 21.9 min wall.
Its speed is within 2% of M1170 everywhere. The box and harness are unchanged
since 11-07.

**Startup:**

| | Q4-21 | Q8-21 | M1170b |
|---|---|---|---|
| start to healthy | 10 s | 10 s | 16 s |
| weights a card | 9.04 GiB | 13.88 GiB | 8.50 GiB |
| KV cache a card | 21.54 GiB | 16.67 GiB | — |
| full 262K sessions in the pool | 5.0 | 3.8 | 5.3 |

**Cold prefill, tok/s:**

| prompt tokens | Q4-21 | Q8-21 | M1170b |
|---|---|---|---|
| ~7.6K | 4,415 | 4,358 | 4,960 |
| ~31K | 4,018 | 3,967 | 4,499 |
| ~64K | 3,561 | 3,521 | 3,938 |
| ~128K | 2,896 | 2,872 | 3,146 |
| ~201K | 2,393 | 2,381 | 2,571 |
| ~254K | 2,127 | 2,117 | 2,266 |

**Decode after a prefix hit, tok/s (512 tokens):**

| prompt tokens | Q4-21 | Q8-21 | M1170b |
|---|---|---|---|
| ~7.6K | 200 | 168 | 210 |
| ~31K | 199 | 173 | 234 |
| ~64K | 177 | 145 | 205 |
| ~128K | 152 | 132 | 166 |
| ~201K | 144 | 126 | 167 |
| ~254K | 142 | 113 | 168 |

**Short-prompt decode, tok/s, rust / python / prose, mean of 2:**
- Q4-21: 166 / 235 / 147.
- Q8-21: 135 / 174 / 123.
- M1170b: 187 / 281 / 157.

**Concurrency at 45K, wall seconds for N = 1 / 2 / 4:**
- Q4-21: 13.2 / 27.6 / 54.9.
- Q8-21: 13.6 / 27.7 / 55.8.
- M1170b: 11.8 / 24.9 / 48.0.

**Turns at ~110K.** Two sessions interleaved, 4 turns each:

| | turn 1 TTFT | turns 2–4 TTFT | section wall |
|---|---|---|---|
| Q4-21 | 36.2–36.4 s | 1.09–1.65 s | 85.7 s |
| Q8-21 | 36.2–36.4 s | 1.04–1.65 s | 85.7 s |
| M1170b | 33.2–33.3 s | 0.97–1.56 s | 78.2 s |

**GSM8K at ~150K** (500 questions, 1024-token cap, thinking off):

| | correct | truncated | s/question, mean / median | tokens/answer | wall |
|---|---|---|---|---|---|
| Q4-21 | 477/500 = 95.40% | 14 | 3.01 / 2.78 | 367 | 25.9 min |
| Q8-21 | 473/500 = 94.60% | 15 | 3.24 / 2.98 | 367 | 27.9 min |
| M1170b | 480/500 = 96.00% | 9 | 2.53 / 2.38 | 335 | 21.9 min |

The per-question figures leave out question 0, which pays the cold 150K prefill:
56.5 s on Q4-21, 56.7 s on Q8-21 and 51.8 s on M1170b.

McNemar exact, paired by question:
- **Q4-21 against M1170b:** 5 right only on Q4-21, 8 only on M1170b.
  p = 0.581, agreement 97.4%.
- **Q8-21 against M1170b:** 2 against 9, p = 0.065, agreement 97.8%.
- **Q4-21 against Q8-21:** 6 against 2, p = 0.289, agreement 98.4%.

Sanity, the tool-call check and the thinking-on reply passed on all three arms.

## What it means

**On this box at TP=2, 2.1.0 with either IQR file is slower than 1.17.0 MXFP4
on every section.** Against M1170b:
- **IQ4R-L-V4:**
  - Cold prefill is 6–11% slower, the gap shrinking with depth.
  - Decode after a hit is 5–16% slower, and short-prompt decode 6–16% slower.
  - Concurrency at 45K and the turns section are 10–14% slower.
- **IQ8R-dflash:** prefill is level with IQ4, but decode is 20–38% slower than
  MXFP4. That is the 8-bit weight read, the same shape FP8 showed on 1.17.0.

The engine and the weights changed together, so this run cannot say how much of
the gap is 2.1.0 and how much is the format. StillDeadcode's card says
IQ4R-S-V4 decodes one stream 4% faster than the MXFP4 checkpoint. That claim is
for a smaller file (4.1 bpw, against 4.8 here) on one card, and it was not
reproduced here.

**GSM8K shows no quality gain to pay for the speed.**
- Neither IQR arm is distinguishable from MXFP4: p = 0.58 and 0.065.
- IQ8R's claimed ninth of FP8's KL did not show up as a better score. It is
  the lowest of the three, but not significantly.
- Both IQR arms write 367-token answers, against MXFP4's 335. FP8 on 1.17.0
  also wrote 367 ([runs/2026-11-07-radiance-1170-fp8-vs-mxfp4](2026-11-07-radiance-1170-fp8-vs-mxfp4.md)).
  The longer answers hit the cap more often (14–15 truncated against 9), and
  they account for part of the per-question time.

GSM8K is arithmetic with thinking off. It says nothing about long code or prose,
and KL is a distribution measure that this harness does not take.

**The KV pool is about the same for IQ4.** 5.0 full 262K sessions against 5.3.
IQ8R's larger weights cut it to 3.8.

**Not measured:**
- Repeats. Each point ran once.
- Code and prose quality (Aider Polyglot, LiveCodeBench).
- 2.1.0 at the drafted 200K window. It changes only the pool and the host tier,
  not the per-step cost.
- Flash Next on 2.1.0 (`qwen3.8-next-flash-iqr-v4.rad`), which was downloaded
  but not run.
- Smaller IQR-V4 sizes such as IQ4R-S, the one StillDeadcode's speed claim is
  for.
