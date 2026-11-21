---
type: Run
date: 2026-11-19
subject: "radiance 2.1.0 Flash Next IQR-V4 against 1.17.0 Flash Next, code and real use"
harness: "~/bench/code/code-bench.sh flash2 (off-repo, on the box): the 11-07/11-08 harness with a flash2 arm and an api_model helper that requests the arm as Qwen3.8, since 2.x refuses any other model id; LiveCodeBench registers Qwen3.8 under model_repr qwen38-flash2. ~/bench/flash/memwatch.sh logs MemAvailable and swap every 10 s. Real use: Prometheus on the nuc, radiance /metrics via Alloy, queried with a scratch script (not kept). Raw: polyglot-flash2.log, aider/tmp.benchmarks/2026-11-19-13-55-50--polyglot-flash2/, LiveCodeBench/output/qwen38-flash2/, lcb-flash2.log, serve-flash2.log, memwatch-flash2.log, code-bench-flash2.log"
box: kinoite-north
---

# radiance 2.1.0 Flash Next IQR-V4 against 1.17.0 Flash Next, code and real use

## What was measured

The shipped `radiance-flash2` unit, image latest.20261119131257, against the
1.17.0 Flash Next arm of
[runs/2026-11-08-radiance-1170-flash-next](2026-11-08-radiance-1170-flash-next.md).
The 1.17.0 figures are copied from that run, not rerun. The code bench ran on
2026-11-19 between 08:55 and 11:11 EST.

**Engine:** radiance 2.1.0, `c9affc48…`.

**Model:** `StillDeadcode/qwen3.8-next-flash-iqr-v4` at revision `679c943`,
sha256 `25aff8c9…`, 122 GB. The 11-08 arm ran
`qwen3.8-next-flash-fp8-iq4r-moe` on 1.17.0, which 2.x refuses to load.

**Settings:** `/etc/radiance/radiance-flash2.yaml` as shipped. They are the
11-08 flags in 2.x keys, with these differences:
- KV cache is int8 (`i8`), since 2.x has no fp8 KV. 11-08 used fp8.
- `prefix-cache-mib: 4096`. 11-08 left it at the engine default.
- `gpu-headroom-mib` is the 2.x default of 96 MiB, the same value.
- Sampling and reasoning defaults are those of every shipped unit.

**Placement per card**, from the startup log:
- 26.50 GiB of VRAM weights, of which 23.30 GiB are experts.
- The KV pool is 387,428 tokens, which the engine reports as 1.9 full-length
  200K sessions. 1.17.0 reported 5.5.
- The 47.7 GiB n-gram table is read from disk.

**Conditions:** 235 W cap on both cards and the powersave governor, as on
11-08.

**Code:** the 11-07 harness, unchanged except for the model id:
- Polyglot: 225 exercises, diff edit format, 2 tries, 8 threads.
- LiveCodeBench: `release_v6` from 2024-10-01, 341 problems, 40,960-token cap,
  8 in parallel.
- Thinking at medium, temperature 0.

**Real use** is the pi harness on `:8005`, from radiance's Prometheus metrics:
- 1.17.0 `radiance-flash`: 2026-11-17 09:45–22:50.
- 2.1.0 `radiance-flash2`: 2026-11-18 08:30 to 2026-11-19 08:50, before the
  code bench started.
- The series carry no unit label. Each window held one engine only, which the
  KV size confirms: 1,102,612 tokens against 387,428 throughout.

## Numbers

**Aider Polyglot:**

| | 2.1.0 IQR-V4 | 1.17.0 (11-08) |
|---|---|---|
| pass rate after two tries | 85.8% (193) | 87.6% (197) |
| pass rate on the first try | 46.2% (104) | 45.8% (103) |
| well-formed edits | 99.6% | 99.6% |
| error outputs | 1 | 1 |
| test timeouts | 1 | 1 |
| seconds per exercise | 56.1 | 92.4 |
| wall | 28 min | 47 min |

Paired exercise by exercise, with an exact McNemar test:
- After two tries: 11 exercises passed only on 1.17.0 and 7 only on 2.1.0,
  p = 0.48.
- On the first try: 16 against 17, p = 1.0.

Passes after two tries by language, 2.1.0 against 1.17.0:

| cpp (26) | go (39) | java (47) | javascript (49) | python (34) | rust (30) |
|---|---|---|---|---|---|
| 21 / 22 | 32 / 34 | 38 / 39 | 44 / 44 | 31 / 32 | 27 / 26 |

**LiveCodeBench, pass@1:**

| | 2.1.0 IQR-V4 | 1.17.0 (11-08) |
|---|---|---|
| easy (84) | 82 = 97.6% | 83 = 98.8% |
| medium (105) | 90 = 85.7% | 85 = 81.0% |
| hard (152) | 74 = 48.7% | 66 = 43.4% |
| **all (341)** | **246 = 72.1%** | 234 = 68.6% |
| no code returned | 61 | 78 |

Paired, with an exact McNemar test:
- All problems: 29 passed only on 2.1.0 and 17 only on 1.17.0, p = 0.10,
  agreement 86.5%.
- Hard problems: 20 against 12, p = 0.22.
- Medium problems: 9 against 4, p = 0.27.
- Easy problems: 0 against 1.

**LiveCodeBench requests**, from `serve-flash2.log`, unique request lines:

| | 2.1.0 IQR-V4 | 1.17.0 (11-08) |
|---|---|---|
| finished on `length` (the 40,960 cap) | 61 | 78 |
| mean tokens generated | 12,305 | 13,973 |
| decode per request, mean / median | 92.5 / 94.7 tok/s | 60.7 / 58.8 |
| wall | 1 h 48 min | 3 h 07 min |

The 2.1.0 counts include one Polyglot request that finished as LiveCodeBench
started: 342 lines for 341 problems.

**Host memory.** MemAvailable stayed at or above 14.2 GiB through both
benches, with LiveCodeBench's 16 GiB container. The low was at 11:11. On
11-08 the floor was 8.0 GiB. Swap stayed at 0.

**Real use**, pi on `:8005`:

| | 2.1.0 IQR-V4 | 1.17.0 |
|---|---|---|
| requests | 3,623 | 2,287 |
| prompt tokens per request | 84,065 | 71,782 |
| generated tokens per request | 2,238 | 2,114 |
| share of prompt tokens served from the prefix cache | 0.902 | 0.907 |
| draft acceptance | 0.849 | 0.831 |
| per-stream decode, from mean inter-token latency | 146 tok/s | 81 |
| – with 1 request running | 162 | 105 |
| – with 2 or more running | 135 | 68 |
| mean time to first token | 2.38 s | 1.96 s |
| mean request time | 13.8 s | 21.3 s |
| mean requests running while busy | 1.6 | 2.1 |
| preemptions, KV stream misses | 0, 0 | 0, 0 |

## What it means

**2.1.0 with the IQR-V4 file writes code as well as 1.17.0 did.**
- Polyglot is level: 85.8% against 87.6%, p = 0.48.
- LiveCodeBench leans towards 2.1.0, 72.1% against 68.6%, p = 0.10. The lean
  is on medium and hard problems.
- Neither difference is significant. Each arm ran once.

**It thinks in fewer tokens.** Mean output on LiveCodeBench fell from 14.0K to
12.3K tokens, and 17 fewer problems hit the cap. 61 requests hit the cap and
61 problems returned no code, so most of the LiveCodeBench lean is likely
fewer answers cut off. That is inferred, not matched problem by problem.

**It is faster where 1.17.0 was weakest.**
- Several long decodes at once: about 95 tok/s per request at 8 in parallel,
  against about 59. LiveCodeBench finished in 1 h 48 min against 3 h 07 min.
- Real use: decode per stream is about 1.8× faster, and about 2× with two or
  more requests running. Mean request time is about 35% shorter.

**Time to first token is a little longer**, 2.38 s against 1.96 s. Prompts were
deeper (84K against 72K tokens), and the KV pool is about a third of 1.17.0's.
The prefix cache still served the same share of prompt tokens, with no
preemptions or misses.

**It needs less host RAM headroom**: a floor of 14.2 GiB against 8.0 GiB under
the same LiveCodeBench container.

**The engine and the model file changed together.** 2.x refuses the 11-08
file, so this cannot separate the engine's effect from the quantization's.

**Not measured:**
- Repeats. Each arm ran once.
- GSM8K, and code at depth: the code benches' prompts are short.
- Quality in real agentic sessions, beyond the request counts above.
- `tp-wire: exact`, a larger `host-pool-mib`, and fp8 against int8 KV, which
  2.x cannot run.
