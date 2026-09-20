---
date: 2026-09-20
subject: "radiance MXFP4 against the Q8XL daily driver on GSM8K at 150K, and what the 512-token cap was hiding"
harness: ~/bench/radiance/quality/gsm8k-deep.py (off-repo, on the box) — quality/gsm8k.py with one shared deep prefix prepended; driven by ~/bench/kvdepth/q8quality.sh for the lemonade arm and ~/bench/radiance/arm-kv.sh (MODE=gsm8k) for radiance. Raw output ~/bench/kvdepth/gsm8k-{q3-q8xl,q-radiance}.jsonl, arm-{q3-q8xl,q-radiance}.log; the superseded 512-cap pair is gsm8k-{q-q8xl,c-fp8}.jsonl
box: kinoite-north
---

# radiance against the daily driver at depth, and the cap that hid it

## What was measured

[runs/2026-09-15-radiance-gsm8k-q8xl](2026-09-15-radiance-gsm8k-q8xl.md) compared
the two at **zero depth** and found no difference (88.80% against 88.00%,
p = 0.618). Every throughput run since has widened radiance's speed lead —
3.7x decode and 3.9x prefill at 170K
([runs/2026-09-20-prefill-and-decode-at-operating-depth](2026-09-20-prefill-and-decode-at-operating-depth.md))
— which makes the quality question the one that decides whether it could be a
daily driver. Nothing had compared the two at the depth this box actually runs.

**Design.** 500 GSM8K questions in file order, identical in both arms, each asked
from behind the same shared filler prefix of **149,753 tokens**. The prefix leads
a single user message and is byte-identical across requests, so after the first
question it is a prefix-cache hit and each further question costs only its own
tokens. Greedy, temperature 0, thinking off. Prompt depth per question was
identical in both arms: min 149,808, median 149,841, max 149,925.

**Arms.** radiance is `serve-mxfp4.sh` at its defaults (MXFP4 weights, DFlash2,
R4D, fp8 KV, the measured KV pin). Q8XL is **lemonade as it ships** —
`Qwen3.8-27B-Q8XL`, `--parallel 4 --kv-unified`, ctx 262144 — not a raw
`llama-server` stand-in, because lemonade is the thing that would be replaced.

**This run supersedes a first attempt at `max_tokens` 512, which measured the
cap rather than the models.** At 512 the two arms truncated at different rates
(radiance 39, Q8XL 58), a truncated answer almost never carries its final number,
and the difference in truncation was larger than the difference in score. That
attempt is recorded below because the size of the artifact is the most useful
thing in this run.

**`reasoning_effort` differs between the arms and is inert.** lemonade pins
`medium` on its Qwen3.8 recipes; radiance sets no pin. With thinking off the knob
changes nothing — the same question at `None`, `low`, `medium` and `xhigh`
returned identical prompt tokens (67) *and* identical completion tokens (279) on
Q8XL, so the template renders the same text either way. The two chat templates
(`qwen-fixed-v22.3.jinja` against the GGUF's embedded one) also render to the same
length at depth, as the identical prompt-token min/median/max show. So neither arm
was given more room to reason than the other.

## Numbers

At `max_tokens` 1024:

| | radiance | Q8XL daily driver |
|---|---|---|
| GSM8K at ~150K | **480/500 = 96.00%** | **475/500 = 95.00%** |
| truncated at 1024 | 9 (1.8%) | 14 (2.8%) |
| errors | 0 | 0 |
| median completion | 304 tok | 337 tok |
| p90 completion | 493 tok | 539 tok |
| mean completion | 332 tok | 370 tok |
| wall | 26.0 min | 73.2 min |

Paired, question by question:

| | count |
|---|---|
| both correct | 473 |
| radiance only | 7 |
| Q8XL only | 2 |
| both wrong | 18 |
| **agreement** | **98.2%** |

| subset | n | radiance | Q8XL | discordant | exact p |
|---|---|---|---|---|---|
| all 500 | 500 | 96.00% | 95.00% | 9 (7/2) | **0.1797** |
| neither arm truncated | 485 | 97.73% | 97.53% | 3 (2/1) | 1.0000 |

Paired difference radiance − Q8XL: **+1.00 points, 95% CI [−0.17, +2.17]**.

### What the 512 cap was doing

The superseded attempt, same prefix, same questions, same order:

| | radiance | Q8XL |
|---|---|---|
| at `max_tokens` 512 | 91.60% | 88.20% |
| at `max_tokens` 1024 | 96.00% | 95.00% |
| change | **+4.40** | **+6.80** |
| truncated at 512 | 39 (7.8%) | 58 (11.6%) |

At 512 the paired test read radiance 91.60% against Q8XL 88.20%, 35 discordant
pairs, **p = 0.006** — apparently significant. On the 436 questions where neither
arm truncated, the same data read 97.94% against 98.17%, 3 discordant pairs,
p = 1.00. The headline and the subset disagreed completely, which is the signature
of an artifact rather than an effect.

## What it means

**No detectable quality difference at 150K depth.** 96.00% against 95.00%, 9
discordant pairs out of 500, p = 0.18. radiance's 4-bit MXFP4 weights, W4A8
kernels and uncalibrated fp8 KV cost nothing measurable against Q8_K_XL on this
task at this depth.

**The bound is tight, because agreement is high.** 98.2% of questions are scored
the same way by both engines, so the paired design is far more sensitive than the
sample size alone suggests: the 95% CI on the difference is [−0.17, +2.17] points,
**ruling out radiance being worse by more than about 0.2 points.** This is a much
stronger statement than the 09-15 zero-depth run could make, whose 36 discordant
pairs left it able to exclude only gross damage.

**The result is robust where the first attempt was not.** The full set and the
non-truncated subset now agree (p = 0.18 and p = 1.00, both null, both nominally
favouring radiance by ~1 and ~0.2 points). At 512 they contradicted each other.
Agreement between the two readings is what makes this one worth quoting.

**The 512-token cap was worth 6.8 points to the daily driver and 4.4 to
radiance.** That is the largest single correction in this repo's GSM8K numbers,
and it is not specific to these arms: **every GSM8K figure measured here under a
512 cap understates the engine**, including the 88.80/88.00 pair in
[runs/2026-09-15-radiance-gsm8k-q8xl](2026-09-15-radiance-gsm8k-q8xl.md), which
flagged the cap as "the largest artifact" and was right by more than it knew. The
correct reading of that run is unchanged — it found no difference, and so does
this — but its absolute numbers are low by roughly 5–7 points.

**It also cost the arms asymmetrically, which is why the first attempt looked
significant.** Q8XL writes longer solutions — median 337 tokens against 304, p90
539 against 493 — so it collided with the cap more often, and a cut-off answer
loses its final line. The apparent 3.4-point radiance win at 512 was that
collision, not arithmetic.

**radiance did the same work in 26.0 minutes against 73.2.** 2.8x, consistent
with the decode figures measured separately.

Nothing is adopted. radiance remains hand-started and unshipped; lemonade's
recipes are unchanged and were restored after both arms.

Not measured:

- **anything but arithmetic.** GSM8K is one task with a short, verifiable answer.
  Tool-call correctness across many turns, long-context retrieval, instruction
  adherence and code generation are all unmeasured, and are where 4-bit weights
  would more plausibly show. A daily driver is judged on those, not on this
- **thinking on.** Both arms ran `enable_thinking: false`, matching 09-15. What
  4-bit weights do to a long reasoning trace is a separate question, and one the
  1024 cap would not have room for
- **any depth but ~150K.** One point on the depth axis
- **repeats.** One run per arm
- whether radiance's terser answers cost it on harder problems, where more working
  genuinely helps. On GSM8K it does not; that does not generalise
- the de-privileged quadlet posture was not re-verified here; it was measured free
  in [runs/2026-09-15-radiance-quadlet-floor](2026-09-15-radiance-quadlet-floor.md)
