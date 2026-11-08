---
type: Run
date: 2026-11-07
subject: "radiance 1.17.0: FP8 against MXFP4 on Aider Polyglot and LiveCodeBench, thinking on"
harness: "~/bench/code/ (off-repo, on the box). code-bench.sh runs as the code-bench.service user unit with the sleep inhibitor, driving the two shipped units in turn. Aider's own benchmark harness in the localhost/aider-benchmark image; LiveCodeBench in localhost/lcb-client (lcb.Containerfile, lcb-register.py). Raw: polyglot-{fp8,mxfp4}.log, aider/tmp.benchmarks/*--polyglot-{fp8,mxfp4}/, LiveCodeBench/output/qwen38-{fp8,mxfp4}/, serve-{fp8,mxfp4}.log, metrics-{pre,post}-{fp8,mxfp4}.txt"
box: kinoite-north
---

# radiance 1.17.0: FP8 against MXFP4 on Aider Polyglot and LiveCodeBench, thinking on

## What was measured

This is the code-quality follow-up to
[runs/2026-11-07-radiance-1170-fp8-vs-mxfp4](2026-11-07-radiance-1170-fp8-vs-mxfp4.md),
on the same box, image, engine, units and 235 W cap. It ran 2026-11-07
14:49–20:34 EST: FP8 first, then MXFP4. Each arm ran Polyglot and then
LiveCodeBench against the unit's server on `:8005`.

Thinking was on at the engine's default reasoning effort, medium, for every
request. Neither client sets an effort. Temperature was 0.

- **Aider Polyglot**: all 225 exercises, `--edit-format diff --tries 2
  --threads 8`. Model `openai/qwen38-{arm}`, which matches none of aider's model
  presets, so aider sent temperature 0 and no token cap. Tests ran inside the
  benchmark container.
- **LiveCodeBench** code generation: `release_v6` from 2024-10-01, which is 341
  problems (84 easy, 105 medium, 152 hard) up to 2025-04-06. Settings were
  `--n 1 --temperature 0 --max_tokens 40960 --multiprocess 8`, scored pass@1.
  A 12-problem smoke test at 16,384 tokens cut off half the hard problems while
  they were still thinking, so the cap was raised to 40,960. Whether those
  problems are in Qwen3.8's training data is not known.

## Numbers

**Aider Polyglot:**

| | FP8 | MXFP4 |
|---|---|---|
| pass rate after two tries | 67.6% (152) | 66.2% (149) |
| pass rate on the first try | 29.8% (67) | 22.2% (50) |
| well-formed edits | 99.1% | 97.8% |
| error outputs | 3 | 9 |
| runs that exhausted the context | 1 | 2 |
| test timeouts | 2 | 0 |
| seconds per exercise | 72.9 | 68.2 |
| wall | 36 min | 34 min |

The two runs were paired exercise by exercise and tested with an exact McNemar
test:
- After two tries: 23 exercises passed only on FP8 and 20 only on MXFP4.
  p = 0.761, agreement 80.9%.
- On the first try: 27 passed only on FP8 and 10 only on MXFP4. p = 0.008,
  agreement 83.6%.

**LiveCodeBench, pass@1.** A problem counts as no code when the reply had no
code block, which almost always means it used the whole 40,960-token cap
while thinking.

| | FP8 | MXFP4 | only FP8 / only MXFP4 | p | agreement | no code, FP8 / MXFP4 |
|---|---|---|---|---|---|---|
| easy (84) | 82 = 97.6% | 83 = 98.8% | 0 / 1 | 1.000 | 98.8% | 0 / 0 |
| medium (105) | 88 = 83.8% | 83 = 79.0% | 12 / 7 | 0.359 | 81.9% | 10 / 8 |
| hard (152) | 55 = 36.2% | 53 = 34.9% | 19 / 17 | 0.868 | 76.3% | 82 / 80 |
| **all (341)** | **225 = 66.0%** | **219 = 64.2%** | 31 / 25 | 0.504 | 83.6% | 92 / 88 |

Both arms returned code on 229 problems. FP8 solved 212 of those and MXFP4
solved 203.

**LiveCodeBench requests, from each unit's serve log.** There were 341 requests
per arm, up to 8 at a time.

| | FP8 | MXFP4 |
|---|---|---|
| finished on `length` (the 40,960 cap) | 92 | 86 |
| mean tokens generated | 17,373 | 16,162 |
| decode per request, mean / median | 89.3 / 84.3 tok/s | 118.5 / 115.7 tok/s |
| wall | 2 h 42 min | 1 h 52 min |

## What it means

**On code, FP8 and MXFP4 score the same once a task is done.**
- Polyglot after two tries: 67.6% against 66.2%, p = 0.76.
- LiveCodeBench: 66.0% against 64.2%, p = 0.50.
- Neither gap is distinguishable from noise at this sample size.

**FP8 gets it right the first time more often.** Polyglot's first-try pass
rate is 29.8% against 22.2%, at p = 0.008. That is the only significant
quality gap in either 11-07 run. FP8 also made fewer badly formed edits, 3
error outputs against 9.

MXFP4 closes the gap on the second try, once aider shows it the failing tests.
For interactive use, that means one fix round fewer, some of the time, with
FP8. The LiveCodeBench subset where both arms returned code leans the same
way: 212 against 203. That subset was not tested for significance.

**MXFP4 is faster.**
- LiveCodeBench took 31% less wall time.
- Per-request decode was 33% faster at 8 concurrent requests.
- On Polyglot it was only 7% faster per exercise, because test runs and prefill
  cost both arms the same.

**On the hard problems, the score is set by how long the model may think.**
Of 152 hard problems, 82 on FP8 and 80 on MXFP4 used the full 40,960 tokens
without producing code. Both quants spend about the same number of tokens
reasoning: FP8 averaged 7% more. Raising the cap would raise both scores. The
cap, not the quant, is the main limit on the hard set.

**Not measured:**
- Repeats. Each arm ran once.
- Any reasoning effort other than medium.
- Any cap above 40,960.
- Anything at 250 W.
- Real multi-step agentic sessions. Polyglot's two tries are the closest thing
  here.
