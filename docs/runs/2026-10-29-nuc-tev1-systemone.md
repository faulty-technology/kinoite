---
type: Run
date: 2026-10-29
subject: "Tev1 4B against Clef-flash on the NUC: same six /v1/systemone samples"
harness: "curl from the laptop over the tailnet. The six request bodies are those inlined in runs/2026-10-24-nuc-clef-flash-systemone, with model set to tev1:4b and nothing else changed."
box: kinoite-nuc
---

# Tev1 4B against Clef-flash on the NUC: same six /v1/systemone samples

## What was measured

The six samples from [runs/2026-10-24-nuc-clef-flash-systemone](2026-10-24-nuc-clef-flash-systemone.md),
sent to `http://nuc:31134/v1/systemone` with `"model":"tev1:4b"`. The bodies are
byte-identical apart from the model name (checked with `jq -S 'del(.model)'`).
Sent one after another from the laptop over the tailnet, 2026-10-29
12:53–12:55 EDT.

Server unchanged from the Clef run: Ollama 0.40.11 in the `clef` pod, Vulkan on
the Iris Xe, `OLLAMA_CONTEXT_LENGTH=8192`. `tev1:4b` was pulled into that
Ollama through `POST /api/pull` minutes before the run. It is Ollama's `tev1:4b`
tag: family `qwen35`, 4.3B parameters, **Q8_0**, 4.6 GB on disk. Clef-flash is
9.1B at Q4_K_M, so this compares the two models as Ollama ships them, not at
equal quantization.

Both models were unloaded (`keep_alive: 0`, `/api/ps` empty) before sample 1.
The Tev1 weights had just been downloaded, so sample 1 is a cold start from page
cache, as Clef's was.

## Numbers

Wall time is curl's `time_total`. Clef figures are from the 10-24 run.

| # | sample | Clef s | Tev1 s | Clef / Tev1 | Clef input_tokens | Tev1 input_tokens |
|---|---|---|---|---|---|---|
| 1 | ticket, 3 q, cold | 6.85 | 8.28 | 0.83× | 451 | 686 |
| 2 | ticket, 3 q, warm | 4.04 | 2.97 | 1.36× | 451 | 686 |
| 3 | routing, 2 q | 2.45 | 1.96 | 1.25× | 260 | 271 |
| 4 | guardrail, 2 q | 2.52 | 2.27 | 1.11× | 297 | 333 |
| 5 | logs, 3 q | 89.28 | 55.86 | 1.60× | 6950 | 20236 |
| 6 | ticket, 12 q | 12.15 | 10.64 | 1.14× | 1222 | 2618 |

Top answers; sample 2 matched sample 1 exactly on both models and is omitted.

| # | question | Clef | Tev1 |
|---|---|---|---|
| 1 | category | bug 0.970 | bug 0.993 |
| 1 | is_urgent | 0.967 | 0.938 |
| 1 | severity | high 0.967 | high 0.997 |
| 3 | route | fast 0.983 | fast 0.987 |
| 3 | needs_tools | 0.016 | 0.010 |
| 4 | is_prompt_injection | 0.967 | 0.958 |
| 4 | risk | high 0.942 | high 0.904 |
| 5 | subsystem | database 0.958 | database 0.993 |
| 5 | has_error | 0.878 | 0.918 |
| 5 | severity | high 0.595 | high 0.889 |
| 6 | category | bug 0.961 | bug 0.993 |
| 6 | is_urgent | 0.964 | 0.936 |
| 6 | severity | high 0.963 | high 0.997 |
| 6 | sentiment | angry 0.943 | angry 0.936 |
| 6 | is_outage | 0.943 | 0.947 |
| 6 | affected_users | team 0.873 | team 0.775 |
| 6 | needs_escalation | 0.947 | 0.970 |
| 6 | mentions_deadline | 0.942 | 0.970 |
| 6 | is_billing_issue | 0.008 | 0.008 |
| 6 | tried_workaround | 0.950 | 0.987 |
| 6 | priority | p0 0.861 | p0 0.613 |
| 6 | channel | web 0.985 | web 0.996 |

- All six requests returned 200 with `output_tokens` 0.
- Tev1 matched every expected answer, 6 of 6, the same as Clef.
- Loaded, Tev1 occupied 5.72 GB (`/api/ps`, all of it on the GPU).

## What it means

**Tev1 is 1.1–1.6× faster here, not the ~2× that half the parameters
suggested.** The gap is widest on long state (89 s → 56 s on the log sample)
and smallest on short calls, where each request still costs about 2 s.

**Tev1 scores each question as its own pass.** Its `input_tokens` grow with the
question count far faster than Clef's: 20,236 for the log sample, well past the
8,192 context, which only fits if the state is counted once per question. Ollama's
API reference says shared context is counted again when questions are scored
separately. The wall times rise much less than those counts, so the repeated
state is probably served from the prompt cache, but this run cannot show that.
In practice Tev1's cost grows with questions × state length, and Clef's with
state length plus the questions.

**Quality is equal on these samples, and Tev1 is more decisive.** It put 0.889
on high severity for the log sample, where Clef split 0.60 / 0.34. It was less
sure on priority for the 12-question ticket, 0.61 p0 against Clef's 0.86. Six
samples cannot rank the two on accuracy or calibration.

**Neither model is sub-second on this iGPU.** Short routing and guardrail calls
take about 2 s on Tev1 and 2.5 s on Clef.
