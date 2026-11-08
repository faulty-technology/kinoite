---
type: Run
date: 2026-11-07
subject: "radiance 1.17.0: FP8 against MXFP4, and 1.17.0 against 1.8.1"
harness: "~/bench/radeng/ (off-repo, on the box), the 10-18 harness unchanged: run-client.sh, radeng-bench.py, gsm8k-deep.py. engine1170.sh drives the two shipped units in turn; inh-run.sh holds the sleep inhibitor. Raw: bench-{M,F}1170.jsonl, gsm8k-{M,F}1170.jsonl, serve-{M,F}1170.log, stats-*-{M,F}1170.json, metrics-post-{M,F}1170.txt"
box: kinoite-north
---

# radiance 1.17.0: FP8 against MXFP4, and 1.17.0 against 1.8.1

## What was measured

Both arms ran through the shipped units, as built in image
`latest.20261107174742`, one after the other on 2026-11-07 13:26–14:32 EST.
Engine: radiance 1.17.0, image `docker.io/stilldeadcode/radiance@sha256:c2acbaa3…`.
The flags are the units' own: `--tp 2 --max-model-len 262144 --max-num-seqs 8
--kv-cache-dtype fp8 --prefix-cache-mib 8192`, with `--checkpoint-slots` at
`auto`. Every bench request sets temperature 0 and thinking off.

- **M1170**: `radiance.service`. The MXFP4 `.rad`, sha256 `a4908940…`, is the
  same file 10-18 ran.
- **F1170**: `radiance-fp8.service`. `StillDeadcode/qwen3.8-27b-fp8` at
  revision `edd43fd`, sha256 `626ab844…`, 30.8 GB. It carries the same DFlash2
  drafter, and the engine picked its stated speculation depth of 7.

Both arms ran at a **235 W** cap per card. `/etc/kinoite/gpu-tune.conf` on the
box sets `POWER_CAP_W=235` and a `FAN_CURVE`, and the cap was read back from
`power1_cap` at the start of each arm. The 10-18 run was at 250 W. So the 1.17.0
against 1.8.1 comparison below has the cap moving against 1.17.0. FP8 against
MXFP4 shares one cap and one window.

## Numbers

**Startup:**

| | M1170 | F1170 |
|---|---|---|
| start to serving | 26 s | 26 s |
| weights a card | 8.50 GiB | 13.81 GiB |
| KV pool, tokens | 1,375,232 (5.2 sessions) | 1,025,408 (3.9 sessions) |
| checkpoint slots | 50 | 50, 7.49 GiB pinned |

Sessions are full-length ones at 262,144. MXFP4's pool was 1,268,272 on 1.3.0
([runs/2026-10-08-radiance-engine-v1-vs-vllm-radiance](2026-10-08-radiance-engine-v1-vs-vllm-radiance.md)),
so 1.17.0 holds 8% more in it. FP8's first start, before this run, logged
1,027,264.

**Cold prefill, tok/s.** B181 is the 10-18 engine arm at 250 W.

| prompt tokens | B181 | M1170 | F1170 |
|---|---|---|---|
| ~7.6K | 4,563 | 5,053 | 4,821 |
| ~31K | 4,151 | 4,583 | 4,362 |
| ~64K | 3,705 | 3,999 | 3,830 |
| ~128K | 3,006 | 3,176 | 3,073 |
| ~201K | 2,487 | 2,585 | 2,521 |
| ~254K | 2,211 | 2,280 | 2,233 |

**Decode after a prefix hit, tok/s (512 tokens):**

| prompt tokens | B181 | M1170 | F1170 |
|---|---|---|---|
| ~7.6K | 208 | 231 | 172 |
| ~31K | 206 | 207 | 151 |
| ~64K | 183 | 189 | 157 |
| ~128K | 160 | 195 | 125 |
| ~201K | 152 | 168 | 129 |
| ~254K | 158 | 165 | 114 |

**Short-prompt decode, tok/s, rust / python / prose, mean of 2:**
- B181: 175 / 257 / 152.
- M1170: 189 / 283 / 158.
- F1170: 132 / 175 / 114.

**Concurrency at 45K, wall seconds for N = 1 / 2 / 4:**
- B181: 12.7 / 24.8 / 47.2.
- M1170: 11.7 / 24.7 / 47.7.
- F1170: 12.5 / 26.0 / 49.6.

**Turns at ~110K.** Two sessions interleaved, 4 turns each:

| | turn 1 TTFT | turns 2–4 TTFT | section wall |
|---|---|---|---|
| B181 | 34.7 s | 1.1–1.8 s | 82.4 s |
| M1170 | 33.0 s | 0.96–1.55 s | 77.5 s |
| F1170 | 33.9 s | 0.98–1.57 s | 81.4 s |

**GSM8K at ~150K** (500 questions, 1024-token cap, thinking off):

| | correct | truncated | s/question, mean / median | tokens/answer | wall |
|---|---|---|---|---|---|
| M1170 | 480/500 = 96.00% | 9 | 2.52 / 2.37 | 335 | 21.8 min |
| F1170 | 477/500 = 95.40% | 12 | 3.16 / 2.92 | 367 | 27.2 min |

The per-question figures leave out question 0, which pays the cold 150K prefill:
51.5 s on M1170 and 53.1 s on F1170.

- **M1170 against F1170:** 8 questions right only on MXFP4, 5 only on FP8.
  McNemar exact p = 0.581, agreement 97.4%.
- **M1170 against B181** (478/500): 3 against 1, p = 0.625, agreement 99.2%.

Sanity, the tool-call check and the thinking-on reply passed on both arms.

## What it means

**1.17.0 is faster than 1.8.1 everywhere it was measured, at 15 W less cap.**
- Cold prefill is 3–11% faster. The gain is largest on short prompts and shrinks
  with depth.
- Decode after a hit is 1–22% faster. Short-prompt decode is 4–10% faster.
- Concurrency at 45K is level.
- Quality is unchanged: same weights, and 99.2% agreement.

The cap difference means these gains are a floor, not a measurement at equal
power.

**FP8 is slower than MXFP4 on decode and level on everything else.**
- Decode after a hit is 17–36% slower, and short-prompt decode 28–38% slower.
  StillDeadcode's cards predicted about 30%.
- Cold prefill is only 2–5% behind. FP8's native WMMA path did not make
  prefill faster.
- Turns and concurrency are within 4–7%, because both are dominated by prefill.

**On GSM8K at depth, FP8 buys nothing.** The 3-question difference is noise.
FP8 writes 9% longer answers, so it hits the cap a little more often. That
makes it about 25% slower per question for the same score. GSM8K is arithmetic
with thinking off, so it says nothing about long code or prose.

**FP8's pool is still big.** At 1,025,408 tokens it is 25% below MXFP4's
1,375,232, and it still clears the ~536–565K peak of observed demand.

**Not measured:**
- Repeats. Each point ran once.
- Anything at 250 W.
- Code and prose quality. That is the next run.
