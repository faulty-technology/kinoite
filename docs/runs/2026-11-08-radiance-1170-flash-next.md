---
type: Run
date: 2026-11-08
subject: "radiance 1.17.0: Qwen3.8 Flash Next against the 27B, speed and code"
harness: "~/bench/flash/ and ~/bench/code/ (off-repo, on the box). flash-serve.sh runs the engine ad hoc as the radiance-flash user unit, since there is no shipped unit; memwatch.sh logs MemAvailable and swap every 10 s. Speed: ~/bench/radeng/run-client.sh with max depth 128000 and no GSM8K. Code: code-bench.sh flash, the 11-07 harness with a flash arm added. Raw: bench-FN1170.jsonl, sanity/toolcheck/think-FN1170.*, flash/smoke.log, flash/memwatch.log, polyglot-flash.log, aider/tmp.benchmarks/*--polyglot-flash/, LiveCodeBench/output/qwen38-flash/, serve-flash.log"
box: kinoite-north
---

# radiance 1.17.0: Qwen3.8 Flash Next against the 27B, speed and code

## What was measured

Same box, image, engine (1.17.0, `c2acbaa3…`) and 235 W cap as
[runs/2026-11-07-radiance-1170-fp8-vs-mxfp4](2026-11-07-radiance-1170-fp8-vs-mxfp4.md)
and [runs/2026-11-07-radiance-1170-code-fp8-vs-mxfp4](2026-11-07-radiance-1170-code-fp8-vs-mxfp4.md).
It ran on 2026-11-08 between 08:52 and 12:57 EST.

**Model:** `StillDeadcode/qwen3.8-next-flash-fp8-iq4r-moe` at revision
`8267a67`, sha256 `0af5e962…`, 122.0 GB.
- Routed experts are 4-bit codebook, and the trunk is int8.
- Drafting uses the model's MTP head. No DFlash2 build of this model exists.
- It is served at 200K. It was trained at 262K.

**Flags:** the model card's command:
```
--tp 2 --tp-wire wht6 --max-model-len 200000 --max-num-seqs 8
--kv-cache-dtype fp8 --placement expert_tiered --host-pool-mib 12288
--gpu-headroom-mib 96 --num-speculative-tokens 3 --max-num-batched-tokens 2048
```
- Plus `--ngram-placement disk` and the shipped units' sampling, reasoning and
  model-id flags.
- The card's `--expert-vs-cache-ratio 0.82` is rejected by 1.17.0 as an unknown
  option, so it was dropped and the engine chose the split itself.
- `--prefix-cache-mib` was left at the engine default. The shipped units set
  8192.
- `--tp-wire wht6` makes the all-reduce between the cards lossy: it sends
  rotated 6-bit data instead of bf16. The scores below include its effect.

**Placement per card**, from the startup log:
- 3.58 GiB static weights, 17.74 GiB experts, 8.55 GiB KV.
- The KV pool backs 5.5 full-length 200K sessions.
- The other experts stream from the 12 GiB pinned host pool.
- The 47.7 GiB n-gram table is read from disk. The memlock limit inside the
  rootless container is 8 MiB, which keeps that table out of locked RAM.
- The engine flagged each card's link as x8 at the host side. It also flagged
  the 235 W cap and the powersave CPU governor. None of these were changed.

**Speed** is the 10-18 client, limited to a 128K maximum depth. **Code** is the
11-07 harness unchanged:
- Polyglot: 225 exercises, diff edit format, 2 tries, 8 threads.
- LiveCodeBench: `release_v6` from 2024-10-01, 341 problems, 40,960-token cap,
  8 in parallel.
- Thinking at medium, temperature 0.

The 27B figures below are copied from the 11-07 runs, not rerun.

## Numbers

Start to serving took 45 s. Sanity, the tool-call check and the thinking-on
reply all passed.

**Single stream, against M1170 (27B MXFP4) from 11-07:**

| | Flash Next | M1170 |
|---|---|---|
| cold prefill ~7.6K / ~31K / ~64K / ~128K, tok/s | 7,214 / 7,171 / 7,031 / 6,789 | 5,053 / 4,583 / 3,999 / 3,176 |
| decode after a hit, same depths, tok/s | 194 / 202 / 198 / 190 | 231 / 207 / 189 / 195 |
| short-prompt decode, rust / python / prose, mean of 2 | 197 / 224 / 175 | 189 / 283 / 158 |
| concurrency at 45K, N = 1 / 2 / 4, wall s | 8.1 / 15.8 / 32.9 | 11.7 / 24.7 / 47.7 |
| turns at ~110K, turn 1 / turns 2–4 TTFT | 20.1–21.7 s / 0.44–0.60 s | 33.0 s / 0.96–1.55 s |

**Aider Polyglot:**

| | Flash Next | FP8 | MXFP4 |
|---|---|---|---|
| pass rate after two tries | 87.6% (197) | 67.6% (152) | 66.2% (149) |
| pass rate on the first try | 45.8% (103) | 29.8% (67) | 22.2% (50) |
| well-formed edits | 99.6% | 99.1% | 97.8% |
| error outputs | 1 | 3 | 9 |
| test timeouts | 1 | 2 | 0 |
| seconds per exercise | 92.4 | 72.9 | 68.2 |
| wall | 47 min | 36 min | 34 min |

The runs were paired exercise by exercise and tested with an exact McNemar
test:
- Against FP8, after two tries: 48 exercises passed only on Flash Next and 3
  only on FP8, p = 2e-11.
- Against FP8, on the first try: 50 against 14, p = 7e-6.
- Against MXFP4, after two tries: 51 against 3, p = 3e-12.
- Against MXFP4, on the first try: 60 against 7, p = 1e-11.

During Polyglot, 2 requests were aborted when they hit aider's 600 s request
timeout, about 26K tokens into thinking.

**LiveCodeBench, pass@1:**

| | Flash Next | FP8 | MXFP4 |
|---|---|---|---|
| easy (84) | 83 = 98.8% | 82 = 97.6% | 83 = 98.8% |
| medium (105) | 85 = 81.0% | 88 = 83.8% | 83 = 79.0% |
| hard (152) | 66 = 43.4% | 55 = 36.2% | 53 = 34.9% |
| **all (341)** | **234 = 68.6%** | 225 = 66.0% | 219 = 64.2% |
| no code returned | 78 | 92 | 88 |

Paired results for Flash Next:
- Against FP8, all problems: 25 passed only on Flash Next and 16 only on FP8.
  p = 0.211, agreement 88.0%.
- Against FP8, hard problems: 19 against 8, p = 0.052.
- Against MXFP4, all problems: 34 against 19, p = 0.053, agreement 84.5%.
- Against MXFP4, hard problems: 25 against 12, p = 0.047.

**LiveCodeBench requests**, 341 per arm. Each request is printed twice in
`serve-flash.log`, once by the engine and once by podman; counts are of unique
lines.

| | Flash Next | FP8 | MXFP4 |
|---|---|---|---|
| finished on `length` (the 40,960 cap) | 78 | 92 | 86 |
| mean tokens generated | 13,973 | 17,373 | 16,162 |
| decode per request, mean / median | 60.7 / 58.8 tok/s | 89.3 / 84.3 | 118.5 / 115.7 |
| wall | 3 h 07 min | 2 h 42 min | 1 h 52 min |

**Decode per stream against concurrency**, from the LiveCodeBench request
intervals, as seconds spent at each level:

| streams running | combined tok/s | tok/s per stream |
|---|---|---|
| 3 | ~144 | 48 |
| 4 | ~194 | 48 |
| 5 | ~242 | 49 |
| 8 | ~435 | 54 |
| 9 | ~540 | 60 |

**Host memory.** MemAvailable was about 22 GiB while serving with no client,
and about 20 GiB through Polyglot. LiveCodeBench's own container, a 16 GiB
cap, took it to 12.3 GiB, with a floor of 8.0 GiB at 12:56. Swap stayed at 0
throughout.

## What it means

**Flash Next writes better code than either 27B build.**
- Polyglot after two tries is 87.6% against 66–68%, by a wide margin (p ≤ 2e-11).
  The first-try gap is as large.
- On LiveCodeBench the overall gap is small: 68.6% against 64–66%. All of it is
  on the hard problems, 43.4% against 35–36%, at about p = 0.05.
- Easy and medium problems are level.

**It thinks more efficiently.** It averaged 14.0K tokens per LiveCodeBench
problem against 16–17K, and hit the cap on 78 problems against 86–92. Most of
its hard-problem failures, 73 of 86, are still the cap. The cap remains the
main limit there, for every model run.

**On speed, it depends on how many requests run at once.**
- **One stream:** it matches the 27B on decode, at 190–202 tok/s, and holds
  that from 8K to 128K. Prefill is 1.4–2.1× faster and grows with depth. Turns
  and concurrency at 45K are about 30% faster.
- **Several long decodes at once:** each stream falls to about 50–60 tok/s, a
  level that holds from 3 to 9 streams, so combined throughput grows with the
  count. At 8 streams it is 435–540 tok/s, about half of MXFP4's ~950.
- That is why LiveCodeBench took 3 h 07 min against 1 h 52 min, despite fewer
  tokens.
- The likely cause is that several streams route to the union of their experts.
  Those that are not resident stream over the x8 links. That is inferred, not
  measured.

**Context:** it is served at 200K against the 27B's 262K.

**It runs in host RAM the 27B does not need.** The 12 GiB pinned pool plus the
n-gram reads leave about 20 GiB available while serving. That is enough on its
own, but tight beside other heavy work.

**Not measured:**
- Repeats. Each arm ran once.
- GSM8K, and anything deeper than 128K.
- `--tp-wire exact`.
- The prefix-cache host tier.
- `--expert-profile` and `--expert-pin-top`, which could keep decode-hot
  experts resident and lift multi-stream decode.
- Anything at 250 W, or with the performance CPU governor.
- Real agentic sessions.
