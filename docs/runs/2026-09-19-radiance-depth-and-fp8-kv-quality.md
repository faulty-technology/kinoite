---
date: 2026-09-19
subject: "radiance at real operating depth, and whether fp8 KV costs quality at 150K"
harness: ~/bench/radiance/arm-kv.sh (off-repo, on the box), a derivative of the 09-15 arm.sh, driving ~/bench/depth-deep.py (depth.py with two points added) and ~/bench/radiance/quality/gsm8k-deep.py (quality/gsm8k.py behind a shared deep prefix); pool figures parsed by ~/bench/kvdepth/kvparse.py; orchestrated by ~/bench/kvdepth/all.sh. Raw output on the box: ~/bench/kvdepth/{arm,serve,sampler}-{b,c-fp8,c-bf16}.log, gsm8k-c-{fp8,bf16}.jsonl, kv-*.txt
box: kinoite-north
---

# radiance at operating depth, and fp8 KV quality at 150K

## What was measured

[runs/2026-09-15-radiance-mxfp4-dflash](2026-09-15-radiance-mxfp4-dflash.md)
measured radiance's decode-versus-depth series out to 69,751 tokens and found a
slope of 0.05 ms per pass per 1K. This box runs sessions at 150–170K
([runs/2026-09-18-kv-quant-and-slot-count](2026-09-18-kv-quant-and-slot-count.md)),
so the series stopped short of where the work actually happens. That run also
logged `Using KV cache scaling factor 1.0 for fp8_e4m3` — uncalibrated runtime
scaling, whose error accumulates with depth — and listed output quality as not
measured.

Two arms: **B** extends the depth series, **C** pairs fp8 KV against bf16 KV on a
scored task at 150K.

**Image and setup.** `stilldeadcode/vllm-radiance:0.9.3`, digest
`sha256:45694209…`. Upstream's `serve-mxfp4.sh` from the pinned checkout with
every default: DFlash2 at 7 draft tokens, `--attention-backend R4D`,
`--max-model-len 262144`, `--max-num-seqs 8`, `--max-num-batched-tokens 8192`,
`--gpu-memory-utilization 0.98` with `--kv-cache-memory 18563072000` (the
`2x7551-32624` row), prefix caching with `mamba-cache-mode align`. Both cards
capped at 250 W. The same configuration as 09-15.

**Arm B harness.** `depth-deep.py` is `depth.py` with one line changed — the
target tuple becomes `(200, 9500, 38000, 70000, 150000, 170000)`. The four
existing points are kept so the series stays comparable to every prior vLLM depth
record. Invocation `depth-deep.py - 512 3 8000`, matching 09-15's
`depth.py - 512 3 8000`.

**Arm C harness.** `--kv-cache-dtype fp8` is hardcoded in `serve-mxfp4.sh:892`
with no variable behind it, so the bf16 arm passes `--kv-cache-dtype auto` as a
trailing argument, which `serve-mxfp4.sh` forwards after its own flags and
argparse resolves last-wins — the same mechanism `arm.sh` already uses for
`--host 127.0.0.1`. A dry run confirmed the override lands at argument position
907 against the hardcoded `fp8` at 872, and **both arms gate on the engine's own
reported `kv_cache_dtype=` before running anything**, so a silent no-op fails the
arm instead of producing two identical arms and a confident null.

`gsm8k-deep.py` is `quality/gsm8k.py` with one shared filler prefix prepended to
every question, inside the single user message, so the prefix is byte-identical
across requests and prefix caching pays its prefill once. The filler is built by
`depth.py`'s `/tokenize` calibration loop, so the depth is measured. 500
questions, greedy, thinking off, same order in both arms — directly comparable to
the 500-question run in
[runs/2026-09-15-radiance-gsm8k-q8xl](2026-09-15-radiance-gsm8k-q8xl.md).

**A harness bug voided the first c-fp8 attempt.** `gsm8k-deep.py` posted to
`/v1/tokenize`; vLLM serves `/tokenize` at the root. `depth.py` never hit this
because its base URL carries no `/v1`. The arm failed before generating anything,
was fixed, and was re-run on its own; c-bf16 was unaffected. Both C arms
therefore ran against separate container starts, which is true of the 09-15 arms
as well.

## Numbers

### Arm B — decode versus depth, six points

512 tokens generated, 3 reps, medians, `acc` is mean accepted length. Bracketed
where spread exceeds 2%.

| point | tok/s | ms/pass | acc | 09-15 ms/pass | Δ |
|---|---|---|---|---|---|
| rust (28 tok) | 162.65 | 22.01 | 3.580 | 21.92 | +0.09 |
| python (32 tok) | 227.38 | 22.16 | 5.039 | 22.08 | +0.08 |
| prose (31 tok) | 153.77 | 22.05 | 3.391 | 21.98 | +0.07 |
| control mean | 181.27 | — | 4.003 | (181.94 tok/s) | −0.67 tok/s |
| 189 | 203.61 | 22.51 | 4.584 | 22.46 | +0.05 |
| 9,479 | 178.28 | 24.23 | 4.319 | 24.24 | −0.01 |
| 37,763 | 184.34 [171.97–184.49] | 24.45 | 4.507 | 24.04 | +0.41 |
| 69,751 | 170.13 | 26.20 | 4.457 | 26.10 | +0.10 |
| **149,739** | **155.92** | **29.09** | 4.535 | — | new |
| **169,251** | **146.18 [144.74–149.95]** | **29.71** | 4.344 | — | new |

Slopes in ms per pass per 1K:

| span | slope | arithmetic |
|---|---|---|
| 189 → 69,751 | 0.0530 | (26.20 − 22.51) / 69.562 |
| 69,751 → 169,251 | 0.0353 | (29.71 − 26.20) / 99.500 |
| 189 → 169,251 | 0.0426 | (29.71 − 22.51) / 169.062 |
| 09-15, 189 → 69,751 | 0.0523 | (26.10 − 22.46) / 69.562 |

Startup: healthy after 130 s, peak VRAM 32,522 MiB per card (09-15: 32,528), host
MemAvailable minimum 41,508 MiB (09-15: 41,532). All four markers as expected:
`linear layers: 304/304`, `merged 48 GDN layers`, no eager draft, thinkoff patch
applied. Counters 4,731 drafts, 15,051 of 33,117 draft tokens accepted.

### Arm C — GSM8K at 150K, fp8 KV against bf16 KV

Both arms saw the same shared prefix of 149,753 tokens and the same 500 questions
in the same order. Prompt depth per question: min 149,808, median 149,841, max
149,925, identical in both arms.

| | fp8 KV | bf16 KV |
|---|---|---|
| GSM8K | **458/500 = 91.60%** | **452/500 = 90.40%** |
| truncated at 512 tokens | 39 | 45 |
| errors | 0 | 0 |
| mean completion | 316 tok | 322 tok |
| wall | 25.2 min | 24.6 min |
| KV pool | 943,581 tok | 509,682 tok |
| MiB/token | 0.01876 | 0.03474 |
| max concurrency @ 262,144 | 3.60x | 1.94x |
| mean accepted length | 6.077 | 6.043 |
| prefix-cache hit rate | 97.69% | 98.63% |
| healthy after | 120 s | 150 s |
| peak VRAM per card | 32,523 MiB | 32,511 MiB |

Paired, question by question:

| | count |
|---|---|
| both correct | 443 |
| fp8 correct, bf16 wrong | 15 |
| bf16 correct, fp8 wrong | 9 |
| both wrong | 33 |
| agreement | 95.20% |

Exact two-sided binomial on the 24 discordant pairs: **p = 0.3075**. The normal
McNemar chi-square is not used; at 24 discordant pairs the approximation is not
appropriate.

Identical output text (last 400 characters) in **84 of 500** questions, 16.8%.

## What it means

**Radiance's depth slope does not inflect at operating depth — it flattens.**
0.0530 ms/1K from 189 to 69,751, then 0.0353 from 69,751 to 169,251. The first
figure reproduces 09-15's 0.0523, and the extension answers the question that
record left open: the flat slope is not an artefact of stopping at 70K.

**At 169,251 tokens it still decodes 146 tok/s.** That is 2.6x what the Q8XL
daily driver managed at 69,751 (56.78 tok/s, 09-15), at 2.4x the depth. Against
production vLLM with fp8 KV at 69,751 — 6.78 tok/s
([runs/2026-09-19-vllm-fp8-kv-dtype-depth](2026-09-19-vllm-fp8-kv-dtype-depth.md))
— it is 21x.

**Arm B reproduces 09-15 within 0.41 ms/pass at every shared point**, with peak
VRAM and host memory within 6 and 24 MiB. The 09-15 series is confirmed, not
merely cited.

**fp8 KV shows no quality cost at 150K, and the run cannot rule out a small
one.** 91.60% against 90.40%, p = 0.3075. The nominal difference favours fp8,
which is not a claim that fp8 is better; it is what a 1.2-point gap looks like
when it is noise. With 500 questions this resolves roughly a 5-point swing — the
same power limit that left 09-15's 88.80 vs 88.00 at p = 0.618. **A 2–3 point
loss would not have been detected.**

**Acceptance at depth is also unaffected.** Mean accepted length is 6.077 against
6.043, 0.6% apart, over ~26,000 drafts each. This is an independent read on KV
fidelity and a more sensitive one than exact-match: the DFlash2 drafter is
verified against the target's own logits at every step, so a degraded KV cache
should cost acceptance directly. It does not.

**The greedy-diff probe would have been actively misleading here.** Only 16.8% of
outputs are identical, so fp8 KV perturbs the greedy trajectory in five of six
questions — while accuracy, acceptance and truncation all hold. A diff would have
reported a large, real-looking effect that means nothing about quality. Scoring
was the right instrument.

**Depth is not what drives truncation.** 39 and 45 of 500 hit the 512-token cap,
7.8% and 9.0%, against 10.8% for radiance and 12.8% for Q8XL on the same 500
questions without a deep prefix (09-15). So the cap is a property of GSM8K at
this token budget, not something the 150K prefix introduced.

**The DFlash2 KV-cache-group padding trap is triggered here, and radiance ships
its own mitigation.** Its startup logs
`[radiance] kv cache groups: size 8, 9 groups, 700 blocks/request (upstream would pick size 5)`
— the least-wasteful-group-size patch that
[explanation/vllm-kv-cache-padding.md](../explanation/vllm-kv-cache-padding.md)
had recorded only as reported. Radiance logs 60.00% waste from three padding
layers where the shipped vLLM logs 6.25%. That doc and the overview item are
corrected.

**fp8 KV does not double a hybrid model's pool.** 943,581 against 509,682 tokens
at the same 17.29 GiB pin is a ratio of 1.851. The engine gives the reason:
attention block size is forced to 1648 tokens at fp8 and 832 at bf16 "to ensure
that attention page size is >= mamba page size". The 48 gated-delta-net layers
hold constant state that the KV dtype does not touch, so about 8% of per-token
cost is dtype-independent here. The decomposition is consistent with the logged
mechanism; it was not measured directly.

Nothing is adopted. radiance remains hand-started on :8005 and unshipped; no
quadlet, launcher or pin was modified, and `~/.config/containers/systemd/users/`
was empty at the end as at the start.

Not measured:

- **output quality beyond arithmetic.** GSM8K is one task. Prose, code and
  multi-turn tool use under fp8 KV at depth are still unchecked, as they were
  after 09-15
- **a bf16-KV depth series.** Arm C ran bf16 only on the quality task, so what
  bf16 KV costs radiance in decode is unknown. The pool cost is measured; the
  speed cost is not
- an effect smaller than ~5 points on GSM8K, per the power limit above
- concurrency at depth, agentic replay at 150K, and TTFT/prefill cost at these
  depths. Arm B measures decode only, timed from first content token to last
- repeats. One run per arm. The 37,763 and 169,251 points carry >2% spread and
  are bracketed
- whether the ~150K result extends to 170K for quality. Arm C ran at 150K only
- any comparison against Q8XL at 150K. The 09-15 Q8XL control stops at 69,751
