---
date: 2026-09-18
subject: "lemonade Q8XL with --parallel 4 --kv-unified: slot semantics, concurrency A/B at short and 40K depth, and the shared-pool failure mode"
harness: ~/bench/conc-lemonade.py (off-repo, on the box), N streams released from a threading.Barrier against lemonade's /api/v1, distinct prompt per stream, temperature 0, max_tokens 384; journal mining of `journalctl --user -u lemonade` for slot config and per-request timings
box: kinoite-north
---

# --parallel 4 --kv-unified on the Q8XL daily driver

## What was measured

lemonade passes `--parallel 1` to llama-server. Before the backend swap on
2026-09-12 15:44 (rocm-nightly b1319) the server came up `n_slots = 4,
kv_unified = 'true'` with no flag from lemonade at all; after it, `n_slots = 1,
kv_unified = 'false'` on every load. Nothing in this repo asks for either. The
journal for the four weeks to 2026-09-18 carries 3,967 Q8XL requests and shows
98.4% of busy wall time with exactly one stream running.

Recipe `llamacpp_args` is appended last and merges per flag, so the recipe can
override it. Four configurations were loaded through lemonade on 13305, all
Qwen3.8-27B-UD-Q8_K_XL (`4ca7207`) with `-sm tensor -fa on`, the Q4_0 MTP
drafter and the `medium` reasoning pin, as hand-added recipes alongside the
shipped one:

    stock        ctx_size 131072                            n_slots 1, n_ctx_slot 131072, unified false
    P2           ctx_size 131072  --parallel 2              n_slots 2, n_ctx_slot  65536, unified false
    P4           ctx_size 131072  --parallel 4 --kv-unified n_slots 4, n_ctx_slot 131072, unified true
    P4U256       ctx_size 262144  --parallel 4 --kv-unified n_slots 4, n_ctx_slot 262144, unified true

`--ctx-size` is the total KV pool, not a per-slot size. Without `--kv-unified`
llama.cpp divides it statically — P2 gives each slot a private 65,536 — and
with it the slots share one pool of `ctx_size` cells dynamically. Both bound
the sum of all live contexts by `ctx_size`; the difference is static partition
against dynamic sharing.

## Numbers

Short prompts (22–26 prompt tokens, 384 generated, 3 reps, medians). `wall`
is the batch's wall clock and is the number that matters; `decode-agg` sums
per-stream rates and is meaningless at one slot, where serialized streams each
decode at full speed one after another.

| config | N=1 wall | N=2 wall | N=4 wall | N=4 wall-agg | N=4 ttft |
|---|---|---|---|---|---|
| stock | 6.34 s | 13.15 s | 25.67 s | 59.84 t/s | 0.27–19.71 s |
| P4 | 6.35 s | 9.32 s | 14.19 s | 108.25 t/s | 4.37–4.93 s |
| P4U256 | 6.39 s | — | 13.07 s | 117.55 t/s | 3.16–5.95 s |

Single-stream decode is unchanged: 62.66, 62.67 and 62.20 tok/s for stock, P4
and P4U256. Four concurrent streams finish in 13–14 s against the stock 25.7 s,
a 1.81–1.96x wall-clock win, and the last stream's first token arrives at ~5 s
instead of ~20 s.

Four streams at ~39.2K prompt tokens each (157K in total, distinct filler per
stream so nothing is answered out of a sibling's cache), 384 generated, 2 reps.
Rep 1 is cold, rep 2 re-sends the same four prompts:

| config | rep 1 | rep 2 |
|---|---|---|
| stock | 151.28 s | 121.27 s |
| P4 (131,072 pool) | all four requests failed | — |
| P4U256 (262,144 pool) | 158.81 s | 83.75 s |

P4's failure is the pool bound: four contexts of 39.2K sum to 157K against a
131,072-cell pool, and llama.cpp kills every stream with `srv decode: Context
size has been exceeded` *after* about 1.8 minutes of prefill, then
`update_slots: decode() failed`. A single request larger than the pool is
rejected cleanly before prefill instead, with a 400
`exceed_context_size_error`.

Peak VRAM, the two R9700s:

| config | card 1 | card 2 |
|---|---|---|
| stock | 21,443 MiB | 20,308 MiB |
| P2 | 21,615 MiB | 20,480 MiB |
| P4 | 22,359 MiB | 21,224 MiB |
| P4U256 | 26,964 MiB | 25,828 MiB |

Slots are nearly free; the pool is what costs. Doubling it to 262,144 adds
about 5.5 GiB per card and leaves 5.7 GiB of the 31.9 GiB spare.

## What it means

**Concurrency is worth having and costs nothing at N=1.** Four agents on short
prompts finish in half the time, and per-agent first-token latency improves 4x.
The traffic in the journal is shaped for this: median prompt 124 tokens, p90
11.6K.

**At depth the win is about cache residency, not batching.** Cold, four 39K
prefills cost the same whether they interleave or queue — 158.8 s against
151.3 s, a 5% loss to interleaving. Re-visited, the four-slot pool holds all
four agents' contexts at once and the same batch costs 83.75 s against 121.27 s,
1.45x. That is the same mechanism as the prefix-cache thrash in the journal: at
one slot, 28.5% of requests find a best-slot similarity below 0.5 against 4.3%
in the four-slot era.

**The pool must be sized for the concurrent sum.** 131,072 is enough for one
agent and not for four: the box's own traffic reaches a p90 depth of 45K, and
four of those is 180K. 262,144 covers it and still fits. It is not unbounded —
four agents at 70K each would hit the same wall, in the same ugly way, after
paying for the prefill.

**262,144 is the model's own window, not an overreach.** The GGUF declares
`qwen35.context_length = 262144` and unsloth's card says 262,144 native,
extensible to 1M with YaRN. The 131,072 the recipe had been seeded at was half
of what this model does unaided, so the pool now matches the checkpoint rather
than exceeding it, and no rope scaling is involved at this size. A single
request past the pool is still refused before prefill, so an over-long prompt
fails fast rather than being served badly.

`--parallel 4 --kv-unified` with `ctx_size` 262144 is baked on
`user.Qwen3.8-27B-Q8XL` on the strength of this run. The other six Qwen3.8
recipes are unchanged and still ship one slot.

## Raising the rest of the Qwen3.8 seeds

Added after the above, same day. The other six Qwen3.8-27B recipes sat at
131,072 for the same reason Q8XL did — nothing had read the checkpoint's window.
All seven are now at 262,144. Slots were not added to the six; they still ship
`--parallel 1`.

The heaviest recipe is the binding constraint, so Turbo-Q8 (Q8_0, 31.2 GB, the
largest file after Q8XL) was loaded at 262,144 to check the arithmetic:

    n_slots = 1, n_ctx_slot = 262144, kv_unified = 'false'
    25,048 / 23,911 MiB of 32,624 per card
    61.15 tok/s, 128 tokens on a 24-token prompt

That also clears `-sm tensor` and MTP on a `-Turbo` recipe by loading one, which
the seeds had carried on matching GGUF headers alone. `-Turbo` and `-Turbo-Fast`
are still unloaded.

KV cost, from the two Q8XL loads: 5,521 MiB per card per 131,072 tokens, or
0.0421 MiB/token/card — close to the 0.0444 the build script's ctx arithmetic
assumes, and on the safe side of it. The slope survives the doubling.

The formula's fixed term is per quant, and the one written down is Q6_K_XL's.
It predicts 17,994 MiB per card for 131,072 against 21,443 measured on Q8XL, but
that 3,449 MiB gap is just weights: Q8XL's file is 6.2 GB larger, ~3,100 MiB per
card under an even tensor split, with the rest in the mmproj and compute buffers.
Q8XL's own constant is ~15,623 MiB/card, which predicts 27,262 MiB at 262,144
against 26,964 measured — 1% high, on the safe side. Size a recipe with its own
quant's constant, not this one.
