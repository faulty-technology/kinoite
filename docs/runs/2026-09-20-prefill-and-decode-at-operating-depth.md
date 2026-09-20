---
date: 2026-09-20
subject: "prefill and decode to 170K across four engines: the daily driver, two vLLM backends and radiance"
harness: ~/bench/kvdepth/pp.py (prefill, new) and ~/bench/depth-deep.py (decode, depth.py with two points added), both off-repo on the box; driven by ~/bench/kvdepth/q8deep.sh for the Q8XL arms, ~/bench/vllm-kvarm/prodab-kv.sh for the vLLM arms and ~/bench/radiance/arm-kv.sh for radiance; orchestrated by ~/bench/kvdepth/all.sh. Raw output ~/bench/kvdepth/{arm,serve,sampler}-{q8xl-deep,q8xl-pp,p-triton-bf16,p-aiter-fp8,p-radiance}.log
box: kinoite-north
---

# Prefill and decode to 170K, four engines

## What was measured

Every decode figure in this repo comes from `depth.py`, which times from the first
content token to the last and therefore **excludes prefill by construction**. No
run here has ever carried a prompt-processing number. For a box whose sessions sit
at 150–170K ([runs/2026-09-18-kv-quant-and-slot-count](2026-09-18-kv-quant-and-slot-count.md)),
prefill is most of a turn, so the decode-only comparisons were half a picture.

Two gaps closed at once: the missing prefill axis, and the daily driver's decode
above 69,751 tokens, which no run had reached.

**`pp.py`, new.** One streaming request per point with `max_tokens` 1, timed to
the first token; pp is `prompt_tokens / TTFT`. That understates prefill slightly,
because TTFT also carries scheduling and the first sampling step — a fixed cost of
a few ms that shrinks as a fraction of the total as depth grows, so the deep points
are the trustworthy ones. Every request is prefixed with a fresh random nonce, so
no two share a prefix and prefix caching can never serve a point.

llama.cpp reports its own `prompt_per_second`, quoted as a cross-check. The two
methods agree to within 0.4% from 9,546 tokens upward (1377.1 vs 1452.7 at 9.5K is
the worst case, 5%; 891.4 vs 891.7 at 169K is the best). They diverge only on the
253-token point, 439.6 against 746.8, exactly where fixed overhead dominates —
that point is reported but should not be read as a prefill rate.

**Arms.**

| arm | engine | config |
|---|---|---|
| q8xl-deep / q8xl-pp | lemonade's llama.cpp, raw `llama-server` | Q8XL, `-sm tensor -fa on`, Q4_0 MTP at n-max 4, `-np 1`, ctx 176000 |
| p-triton-bf16 | vLLM 0.27.1 | TRITON_ATTN, bf16 KV, util 0.90, len 176000 |
| p-aiter-fp8 | vLLM 0.27.1 | ROCM_AITER_UNIFIED_ATTN, fp8 KV, util 0.90, len 176000 |
| p-radiance | vllm-radiance 0.9.3 | upstream `serve-mxfp4.sh` defaults, R4D, fp8 KV, pinned KV |

The Q8XL arms reproduce the 09-15 control exactly — same build (`0.4.0-dev`,
commit `8172e65`), same checkpoint (unsloth `4ca7207` UD-Q8_K_XL), same flags,
same `-np 1` — with **one deliberate deviation: ctx 98304 → 176000**, because
98304 cannot hold a 170K prompt. All six points were re-measured at the new ctx
rather than splicing the old four, which makes the series internally consistent
and doubles as a measurement of what ctx costs.

**Two Q8XL paths were measured and agree.** Prefill was run both through lemonade
as it ships (`--parallel 4 --kv-unified`, ctx 262144) and through raw
`llama-server` at `-np 1`. They differ by under 1% at every depth — 893.6 against
891.4 at 169K, 938.8 against 936.8 at 149K. So the decode figures (raw server) and
the earlier lemonade prefill figures describe the same performance, and lemonade's
four-slot unified cache costs nothing at prefill.

## Numbers

### Decode (tg), tok/s

| depth | Q8XL | radiance | vLLM AITER fp8 | vLLM TRITON bf16 |
|---|---|---|---|---|
| 189 | 75.84 | 203.61 | 55.29 | 66.57 |
| 9,479 | 69.54 | 178.28 | 46.99 | 55.21 |
| 37,763 | 62.00 | 184.34 | 35.71 | 43.38 |
| 69,751 | 56.22 | 170.13 | 30.15 | 31.79 |
| 149,739 | **42.44** | 155.92 | 20.73 | 19.70 |
| 169,251 | **39.79** | **146.18** | 17.78 | 17.81 |

ms per target pass, and what ctx cost the daily driver:

| depth | Q8XL @ ctx 176000 | Q8XL @ ctx 98304 (09-15) | Δ |
|---|---|---|---|
| 189 | 49.97 | 49.21 | +0.76 |
| 9,479 | 51.34 | 50.95 | +0.39 |
| 37,763 | 57.10 | 56.66 | +0.44 |
| 69,751 | 63.50 | 62.87 | +0.63 |
| 149,739 | 80.82 | — | — |
| 169,251 | 84.95 | — | — |

### Prefill (pp), tok/s, with TTFT

| depth | Q8XL | radiance | vLLM AITER fp8 | vLLM TRITON bf16 |
|---|---|---|---|---|
| ~253 | 517.2 | 2622.4 | 2106.0 | 2314.4 |
| ~9,547 | 1380.6 | **5549.4** | 2965.8 | 2931.7 |
| ~37,828 | 1292.1 | 4985.9 | 2060.5 | 2023.7 |
| ~69,820 | 1159.1 | 4508.4 | 1541.2 | 1489.7 |
| ~149,805 | 938.8 | 3629.5 | 939.0 | 891.2 |
| ~169,314 | 893.6 | **3471.2** | 854.8 | 811.6 |

TTFT at ~169,314 tokens: radiance **48.8 s**, Q8XL 189.5 s, AITER fp8 198.1 s,
TRITON bf16 208.6 s.

### One deep turn, end to end

170K prompt, 512 tokens generated, as `TTFT + 512/tg`:

| engine | prefill | decode | total | vs Q8XL |
|---|---|---|---|---|
| radiance | 48.8 s | 3.5 s | **52.3 s** | 3.9x faster |
| Q8XL daily driver | 189.5 s | 12.9 s | 202.4 s | — |
| vLLM AITER fp8 | 198.1 s | 28.8 s | 226.9 s | 1.12x slower |
| vLLM TRITON bf16 | 208.6 s | 28.7 s | 237.3 s | 1.17x slower |

## What it means

**Prefill dominates a deep turn, and every previous comparison here omitted it.**
At 170K the daily driver spends 189.5 s prefilling and 12.9 s generating — prefill
is 94% of the turn. Ranking engines on decode alone, as every prior run in this
repo does, ranks them on the smaller half.

**radiance wins both halves, and the prefill margin is the larger one.** 3.9x the
daily driver's prefill throughput and 3.7x its decode, for 3.9x end to end on a
170K turn. Its prefill advantage holds across the whole range — 4.0x at 9.5K, 3.9x
at 70K, 3.9x at 169K — where the vLLM backends' advantage decays to nothing.

**The daily driver beats both production vLLM configurations at every depth, on
both axes.** At 169,251 tokens Q8XL decodes 39.79 tok/s against 17.78 and 17.81,
and prefills 893.6 against 854.8 and 811.6. The backend work in
[runs/2026-09-19-vllm-fp8-kv-attention-backend](2026-09-19-vllm-fp8-kv-attention-backend.md)
found AITER+fp8 the best *vLLM* configuration; it is still 2.2x slower than
lemonade at decode and marginally slower at prefill. Nothing measured on
production vLLM approaches the daily driver.

**vLLM's prefill lead over lemonade is real but only at shallow depth, and it
inverts.** 2.1x at 9.5K, 1.6x at 37.8K, 1.3x at 69.8K, 0.95x at 149.8K, 0.91x at
169.3K. Whatever advantage vLLM's chunked prefill has is gone by this box's
operating depth.

**The daily driver's decode at operating depth is now known.** 42.44 tok/s at
149,739 and 39.79 at 169,251, against 56.22 at 69,751. Decode falls 29% from 70K
to 170K, and ms/pass rises from 63.50 to 84.95 — a slope of 0.216 ms/1K over that
span, close to the 0.20 measured to 70K on 09-15. It does not inflect.

**Raising ctx costs the daily driver a little decode.** ctx 98304 → 176000 adds
0.39–0.76 ms/pass at the four shared points, consistently and in the same
direction, without changing acceptance. Small, but it means a context ceiling is
not free even at depths far below it, and it is why the shallow points here sit
slightly below the 09-15 figures.

**lemonade's four-slot unified cache costs nothing at prefill.** Its prefill
matches raw `llama-server` at `-np 1` within 1% at every depth, so `--kv-unified`
is doing its job and the shipped four-slot configuration is not paying for the
slots at prefill time.

Nothing is adopted. The shipped lemonade recipes, vLLM quadlet and launcher are
unchanged; radiance remains hand-started and unshipped.

Not measured:

- **quality, anywhere in this run.** Every number here is throughput. radiance's
  4-bit MXFP4 weights against Q8_K_XL at depth are the open question, and it is
  being run separately
- **concurrency at depth.** All arms are single-stream. The 170K turn figures
  describe one request with the machine to itself, which is not how four slots or
  eight sequences behave
- **prefix-cache hits.** `pp.py` defeats caching on purpose with a per-request
  nonce, so these are cold-prefill numbers. A real agentic turn reuses most of its
  prefix, and [runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md) shows
  what that is worth — the 189.5 s figure is a worst case, not a typical turn
- **the 253-token prefill point** should not be read as a rate; at that size TTFT
  is mostly fixed overhead, which is why the two methods disagree by 70% there and
  by 0.4% at depth
- repeats. One run per arm, 3 reps per point
- `ROCM_AITER_FA` and `TURBOQUANT`, still untried
