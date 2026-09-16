---
date: 2026-09-15
subject: GSM8K 500-question paired A/B, radiance MXFP4 against lemonade's Q8_K_XL daily driver, greedy with thinking off
harness: ~/bench/radiance/quality/quality.sh (orchestration) and gsm8k.py, against lemonade :13305/api/v1 and radiance :8000/v1; raw output ~/bench/radiance/quality/{run.log,q8.jsonl,radiance.jsonl} (off-repo, on the box)
box: kinoite-north
---

# MXFP4 against Q8_K_XL on GSM8K

## What was measured

The question [runs/2026-09-15-radiance-mxfp4-dflash](2026-09-15-radiance-mxfp4-dflash.md) and
[runs/2026-09-15-radiance-quadlet-floor](2026-09-15-radiance-quadlet-floor.md) both left open: does
serving Qwen3.8-27B at 4 bits cost output quality against the 8-bit daily driver.

**Corpus.** The first 500 questions of GSM8K's test split in file order
(`openai/grade-school-math`, `test.jsonl`, 1,319 questions), the same questions in the same order
for both arms, so the comparison is paired question by question.

**Ask.** Each question plus "Solve this step by step, then give the final numeric answer on the
last line." Temperature 0, thinking off, 512-token cap. The answer is the last number in the reply;
the gold answer is what follows `####`.

**Arms**, sequential because one engine holds the GPUs:

- **Q8XL.** lemonade's shipped `Qwen3.8-27B-Q8XL` recipe on its current rocm-nightly llama.cpp
  (`0.4.0-dev`, commit `8172e65`).
- **radiance.** Upstream's `serve-mxfp4.sh` at the pinned commit: MXFP4 weights, DFlash2 drafter at
  7 draft tokens, R4D attention, FP8 KV cache, 0.98 with the measured KV pin.

Both served the same model family, so this isolates the quantization and the engine around it, not
the model.

## Numbers

| | Q8XL | radiance MXFP4 |
|---|---|---|
| GSM8K | 440/500 = **88.00%** | 444/500 = **88.80%** |
| truncated at the 512-token cap | 64 (12.8%) | 54 (10.8%) |
| truncated *and* scored wrong | 54 | 48 |
| mean completion | 353 tokens | 343 tokens |
| request errors | 0 | 0 |
| wall for all 500 | 41.8 min | 10.7 min |

Paired over the same 500 questions:

| both right | both wrong | only Q8XL | only radiance |
|---|---|---|---|
| 424 | 40 | 16 | 20 |

36 discordant pairs, McNemar exact two-sided **p = 0.618**.

## What it means

**No detectable quality difference.** The arms are 0.8 points apart with p = 0.618, so this run
gives no evidence that 4-bit MXFP4 weights, the W4A8 kernels, or the FP8 KV cache at scale 1.0 cost
accuracy on arithmetic reasoning. Radiance was nominally ahead, which at this sample size means
indistinguishable, not better.

**What it can and cannot rule out.** With 36 discordant pairs the design detects a gross
regression, not a subtle one: a true 2–3 point loss would likely have been missed. It answers "are
the 4-bit weights broken", not "are they equal".

**The 512-token cap is the largest artifact.** About an eighth of answers in both arms ran past it
and therefore scored wrong for never reaching a final number. The rates are within 2 points of each
other, so the cap does not explain the outcome, but both absolute figures are depressed by it.
Upstream's 97.8% GSM8K claim is not comparable to these numbers: different prompt, cap and
thinking setting.

**Speed reproduces the other runs.** The identical 500 questions took 10.7 minutes against 41.8,
a factor of 3.9, in line with the decode figures measured earlier the same day.

Not measured:

- prose and code quality, where 4-bit damage would more plausibly show than in arithmetic
- agentic tool use over many turns
- thinking on, or a larger token cap
- any other quant pair, and any repeat of this run
