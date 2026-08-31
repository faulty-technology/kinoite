# lemonade (llama.cpp) vs vLLM — kinoite-north

Dual Radeon AI PRO R9700 (gfx1201), Qwen3.8-27B on both sides. **This file is the single home
for the engine comparison.** It exists because the same argument had accumulated in three
places — the quant/depth tables in `kinoite-north-validation.md` "Settled", the "STACK
CONSOLIDATION" plan in its "Open", and a 130-line head-to-head baked into the `vllm.md` heredoc
inside `vllm.sh` — with no one place answering "which engine, and why".

Nothing here has been deleted from those files yet; see **What this supersedes** at the bottom.

Conventions follow the main notes: **measured** claims carry a date and a harness, and anything
unverified is labelled as such rather than implied.

---

## Verdict

**llama.cpp is the decode path, and that survives turning vLLM's prefix caching on.** It was
2.01x ahead on end-to-end agentic throughput when vLLM shipped with prefix caching off, and is
still 1.16x ahead now that it ships on. But the *shape* of the win changes completely, and that
is the part worth knowing:

| | vLLM FP8, PC off (pre-08-31) | vLLM FP8, PC on (current) | lemonade Q8XL |
|---|---|---|---|
| warm TTFT | 5.573 s | **0.441 s** | 0.980 s |
| decode | 52.01 t/s | 48.04 t/s | **67.66 t/s** |
| end-to-end | 24.09 t/s | 41.63 t/s | **48.37 t/s** |

With caching off vLLM lost on prefill *and* decode. With it on — the default since 2026-08-31,
flipped on the strength of these numbers — it **wins prefill by 2.2x and loses decode by 1.41x**,
and decode is what dominates once a conversation is warm. So the remaining gap is a genuine
engine-speed gap, not a missing-feature gap.

---

## Measured 2026-08-31 — the agentic multi-turn arm

The one the older harnesses could not see. `depth.py` times first-content-token to last, so
prefill is excluded *by construction*; `concdeep.py` gives every stream a distinct prompt
*specifically* so prefix caching cannot win. Both are right for a decode number and blind to the
thing that actually differs in real use.

`~/bench/agentic.py` (new): one conversation, 8 turns, full history re-sent each turn. Assistant
replies are **canned, not sampled**, so every arm replays a byte-identical growing prefix and
`prompt_tokens` is comparable across engines; temperature 0 and fixed `max_tokens 256` keep decode
work equal. 2 reps. Prompt depth runs 13,042 → 16,204 tokens. Driver `~/bench/pc-compare.sh`,
raw output `~/bench/pc-compare-results.txt`.

| metric | vLLM PC off (pre-08-31) | vLLM PC on (current default) | lemonade Q8XL |
|---|---|---|---|
| TTFT turn 1 (cold) | 4.763 s | 2.652 s | 5.992 s |
| TTFT turns 2+ (warm) | 5.573 s | **0.441 s** | 0.980 s |
| within-conversation TTFT trend | **0.85x (degrades)** | 6.02x | 6.11x |
| decode median | 52.01 t/s | 48.04 t/s | **67.66 t/s** |
| wall per turn | 10.329 s | 5.805 s | **4.724 s** |
| end-to-end | 24.09 t/s | 41.63 t/s | **48.37 t/s** |
| prefix cache hit rate | 0.0 % | 83.6–88.2 % | n/a (automatic) |

**Read the TTFT-versus-turn curve, it is the whole story.** Per-turn TTFT, rep 2:

    turn        1      2      3      4      5      6      7      8     prompt 13.0K -> 16.2K
    vLLM off  4.784  4.984  5.179  5.391  5.596  5.812  6.017  6.229   climbs with depth
    vLLM on   0.401  0.254  0.119  0.309  0.498  0.695  0.185  0.384   flat, no depth trend
    lemonade  0.857  0.936  0.975  0.990  0.993  0.766  1.007  1.004   flat, mild drift

Without caching, TTFT rises **monotonically** with turn number — every turn re-prefills a
conversation that keeps growing, so the agent gets slower the longer you talk to it. That is a
latency pathology, not a throughput one, and no decode benchmark on this box would ever have
shown it.

**Prefix caching costs nothing at decode. Do not quote the tok/s delta as a cost.** The control
means say 55.67 -> 54.23 tok/s (-2.6%), which looks like a real penalty and is not. `ms/pass` —
which `depth.py` documents as "the quantity that is deterministic in depth", tok/s being
acceptance-noise-carrying — is flat everywhere:

| depth | PC off | PC on | delta |
|---|---|---|---|
| short control (3 workloads) | 60.56 ms | 60.69 ms | +0.2 % |
| 189 tok | 60.99 | 60.76 | -0.4 % |
| 9,479 | 75.03 | 75.02 | 0.0 % |
| 37,763 | 117.96 | 117.29 | -0.6 % |
| 69,751 | 164.90 | 165.45 | +0.3 % |

The tok/s difference is mean-accepted-length drift (3.372 -> 3.292). Same reason the deep points
look *faster* with caching on (38K 32.27 vs 31.64; 70K 22.88 vs 21.37, acceptance 3.785 vs
3.732/3.524) — also not real. This confirms the 2026-08-22 finding ("decode unchanged, inside
noise") rather than revising it.

**Both engines reproduced their own recorded baselines the same afternoon**, which is what makes
the arms comparable to the older tables rather than only to each other: vLLM control mean 55.67
against 55.63 recorded, lemonade Q8XL 60.65 against 60.69. Both inside 0.1%.

---

## Measured 2026-08-31 — what the journals say about real use

Independent of any benchmark: server-side counters and logs from actual traffic. This is what
prompted the whole investigation, and it is the strongest evidence because nobody was benchmarking.

**lemonade Q8XL**, `llamacpp:*` Prometheus counters, one 51-minute session (`--ctx-size 131072`,
`-sm tensor -fa on --spec-type draft-mtp --spec-draft-n-max 3`):

    generated                126,284 tokens
    prompt processed         288,903 tokens        -> 2.29 : 1
    per-slot decode rate      29.50 t/s
    mean busy slots/decode     1.723               -> 50.83 t/s aggregate
    prefill rate             513.05 t/s
    max context reached      110,926 tokens

**vLLM FP8**, 4,399 ten-second log windows, 2026-08-16..08-30:

    generated              1,022,800 tokens
    prompt processed      27,918,516 tokens        -> 27.30 : 1
    aggregate while generating 26.57 t/s
    per-stream equivalent      23.09 t/s
    steady-state single-stream 23.7-24.6 t/s (n=1404 clean windows)
    prefix cache hit rate  nonzero in 19 / 4,399 windows

**The 12x prompt:generated ratio difference is the finding.** vLLM was re-prefilling 27.3 prompt
tokens per generated token against llama.cpp's 2.29 — and llama.cpp reached a *deeper* context
(110,926 tokens) while doing it, so this is not a workload artifact. It spent 343 minutes
prefilling against 642 minutes decoding. Amortised per output token:

| | prefill | decode | total | effective |
|---|---|---|---|---|
| vLLM FP8 (PC off, as it ran) | 20.14 ms | 43.31 ms | 63.45 ms | 15.76 t/s |
| lemonade Q8XL | 4.46 ms | 33.90 ms | 38.36 ms | 26.07 t/s |

Caveat kept deliberately: the lemonade sample is 51 minutes of one workload, vLLM's is two weeks
of mixed use. The decode figures are robust on both sides (thousands of samples), the ratio is
partly workload — but 12x is far too large to be anything but the cache.

---

## Measured 2026-08-30 — decode versus depth (unchanged, reproduced above)

Single stream, decode timed first-content-token to last, 512 tokens, median of 3 after a
discarded warm-up, thinking off. llama.cpp with its MTP head; vLLM at its then-shipped defaults
(prefix caching still off; it does not affect decode, see the ms/pass table above).
**The quantisation question is controlled for**: Q8_K_XL is 31.5 GB against vLLM's 27.8 GB FP8,
so llama.cpp reads *more* bytes per token and still wins.

    prompt depth    vLLM FP8      -sm layer         -sm tensor      (Q8_K_XL, 31.5 GB)
       189 tok       63.33      51.96  0.82x      77.39  1.22x
     9,479 tok       49.81      47.96  0.96x      78.58  1.58x
    37,763 tok       31.56      42.63  1.35x      62.14  1.97x
    69,751 tok       21.31      34.05  1.60x      55.67  2.61x

`-sm tensor` wins at every depth; `-sm layer` **loses below ~11.1K** at this quant. Full IQ4_XS
and Q6_K_XL arms, the ms/pass decomposition and the concurrency tables stay in
`kinoite-north-validation.md` — they are quant-selection material, not engine-selection material.

The one place vLLM still wins outright: **4-way short-prompt concurrency**, 189.93 aggregate
against 170.18 (Q8 tensor). It loses 4-way *deep* catastrophically, 60.42 against 148.38.

---

## Where each engine actually wins

| axis | winner | margin |
|---|---|---|
| decode, single stream, any depth | **llama.cpp `-sm tensor`** | 1.22x–2.61x |
| end-to-end agentic, current defaults | **llama.cpp** | 1.16x |
| end-to-end agentic, vLLM caching off | **llama.cpp** | 2.01x |
| warm-prefix TTFT | **vLLM + prefix caching** | 2.2x |
| cold prefill throughput | **vLLM** | ~2.6x (1,355 vs 513 t/s) |
| 4-way short concurrency | **vLLM** | 1.12x |
| 4-way deep concurrency | **llama.cpp** | 2.46x |
| tool calling | see below | — |

**Concurrency semantics differ structurally and it is a planning constraint, not a tuning knob.**
vLLM does continuous batching over a shared paged pool at `--max-num-seqs 4`; a 5th request queues.
llama.cpp uses `-np N` FIXED slots and DIVIDES `-c` across them, so max context per stream is
`c/np` and raising concurrency lowers per-stream context unless total `-c` (and VRAM) rises.

**They cannot run at once.** lemonade Q8XL holds ~22 GB/card and vLLM FP8 needs ~28 GB of 32 GB.
Every comparison here is sequential for that reason.

---

## Tool calling

**GATE CLEARED, measured 2026-08-31.** The open item in `kinoite-north-validation.md` was
"Nothing here has ever sent a tool-calling request through lemonade. If it does not work, stop."
It works. `~/bench/toolcheck.py` sends one `tools` array to `/api/v1/chat/completions` against
the loaded Q8XL and gets back:

    finish_reason : tool_calls
    tool_calls    : 1 returned
      name        : get_weather
      arguments   : {"city":"Reykjavik"}   (well-formed JSON)

So lemonade **does** proxy `tools` through to llama-server and **does** return the parsed
OpenAI `tool_calls` shape, not raw text for the client to scrape. Parsing is the model's own
template via `--jinja` (default-enabled on the shipped b1305 build), with `--reasoning-format
auto` separating `reasoning_content`. Consistent with the surrounding evidence: 285 chat
completions ran in the 2026-08-31 session with zero tool-related errors in the journal.

**vLLM's tool calling is running degraded on purpose, and this is worth weighing.** The launcher
exports `VLLM_ENFORCE_STRICT_TOOL_CALLING=0` whenever speculation is on, because this image
(2026-06-13) is three weeks short of the upstream fix for vllm#44006 — with MTP on, the structural
tag gets fed the reasoning text and rejects it. The costs: tool-call syntax is **not**
grammar-guaranteed, and `tool_choice="required"` or a named function is **silently downgraded to
"auto"**. Measured 2026-08-23: 3/12 requests failed before the workaround, 0/16 after.

So neither engine is grammar-constrained today. **NOT MEASURED:** no A/B of tool-call correctness
between the two has been run — the plural reports that lemonade "feels better at tools" are
consistent with the `tool_choice` downgrade above but are not evidence.

---

## Re-running any of this

    ~/bench/pcache.sh on|off|status     toggle VLLM_PREFIX_CACHING (user drop-in, no root)
    ~/bench/pc-compare.sh               all three arms, ~30 min, restores the box on any exit
    ~/bench/agentic.py <port> <prefix> [base_kb] [turns] [max_tokens] [reps]
    ~/bench/depth.py - 512 3 8000       vLLM decode-vs-depth
    ~/bench/lemctl.py 13305 <model> 512 3   lemonade decode control

`pcache.sh` works by restating the quadlet-generated `ExecStart` with one extra `--env` in
`~/.config/systemd/user/vllm.service.d/`. A `[Service] Environment=` drop-in does **not** work:
the quadlet bakes `Environment=` into the podman argv, so it would set the variable on the podman
client rather than inside the container where `vllm-serve.sh` reads it. `pcache.sh off` deletes
the drop-in and the unit returns to exactly what the image ships.

`agentic.py` needs `BENCH_MODEL=<name>` for lemonade, which lists every *available* model on
`/models` rather than the loaded one, so the usual `data[0]["id"]` idiom picks the wrong model.

---

## Open

- [x] **`VLLM_PREFIX_CACHING` now defaults to true — DONE 2026-08-31**, on the 1.73x end-to-end
      with no measurable decode cost. Changed in `vllm.sh` (the `PREFIX_CACHING` default, the
      "Knobs" entry in the `vllm.md` heredoc, and the head-to-head caveat); `kinoite-north-
      validation.md` updated in both places that stated the old default.

      **The flip does not answer the reason it was opt-in, and that reason is still live.**
      Upstream gates prefix caching for hybrid models — `is_prefix_caching_supported` returns
      False for `attn_type == "hybrid"`, logged at DEBUG — and Qwen3.8-27B is `qwen3_5`, i.e.
      hybrid, so this default overrides an experimental gate. That is a correctness question and
      no throughput number bears on it. Correctness spot-checks passed 2026-08-22 and nothing
      since has contradicted them, but see the quality A/B item below: it has never been run with
      the flag on versus off. `VLLM_PREFIX_CACHING=false` is the single revert.
- [ ] **Tool-call correctness A/B** between the two engines. That lemonade returns a well-formed
      `tool_calls` shape is now measured; that it does so more RELIABLY than vLLM is not. The
      `tool_choice` downgrade above makes the claim plausible but nobody has run the comparison.
- [ ] **Quality A/B between FP8, Q8_K_XL and IQ4_XS.** Never run on this box. Bits-per-weight is
      not an output-quality metric, and every throughput table here is silent on it.
- [ ] **RCCL.** Every `-sm tensor` figure here is a FLOOR — this build has no RCCL, so all tensor
      arms fell back to the generic butterfly reduction (`internal AllReduce init failed`).

---

## What this supersedes

Nothing has been removed from the other files. When trimming them, this file is now the
authority for:

- `kinoite-north-validation.md` "Settled": the **vLLM FP8 column** of the quant tables and the
  "Where Q6 sits against vLLM" prose (~lines 380–530). The IQ4/Q6/Q8 comparison *between quants*
  should stay there — that is quant selection, a different question.
- `kinoite-north-validation.md` "Open": the **STACK CONSOLIDATION** block (~lines 1075–1140).
  Items 1 (tool calling) and 3 (prefix caching) are now answered above; items 2, 4 and 5 (the
  OpenAI surface, concurrency semantics, quantisation quality) are carried forward here.
- `vllm.sh`: the head-to-head inside the `vllm.md` heredoc (~lines 1615–1745). That text ships to
  `/usr/share/kinoite/vllm.md` as vLLM's runbook, so it should keep a short pointer here rather
  than the full tables.
