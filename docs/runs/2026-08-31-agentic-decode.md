---
date: 2026-08-31
subject: lemonade vs vLLM on a multi-turn agentic conversation, prefix caching on and off
harness: ~/bench/agentic.py, driven by ~/bench/pc-compare.sh (off-repo, on the box)
box: kinoite-north
---

# Agentic multi-turn: lemonade vs vLLM

## What was measured

The arm the older harnesses could not see. `depth.py` times first-content-token
to last, so prefill is excluded *by construction*; `concdeep.py` gives every
stream a distinct prompt *specifically* so prefix caching cannot win. Both are
right for a decode number and blind to the thing that actually differs in real
use.

`~/bench/agentic.py`: one conversation, 8 turns, full history re-sent each turn.
Assistant replies are **canned, not sampled**, so every arm replays a
byte-identical growing prefix and `prompt_tokens` is comparable across engines;
temperature 0 and fixed `max_tokens 256` keep decode work equal. 2 reps. Prompt
depth runs 13,042 → 16,204 tokens. Raw output `~/bench/pc-compare-results.txt`.

Qwen3.8-27B on both sides — vLLM FP8 (27.8 GB), lemonade Q8_K_XL (31.5 GB).

## Numbers

| metric | vLLM PC off | vLLM PC on | lemonade Q8XL |
|---|---|---|---|
| TTFT turn 1 (cold) | 4.763 s | 2.652 s | 5.992 s |
| TTFT turns 2+ (warm) | 5.573 s | **0.441 s** | 0.980 s |
| within-conversation TTFT trend | **0.85x (degrades)** | 6.02x | 6.11x |
| decode median | 52.01 t/s | 48.04 t/s | **67.66 t/s** |
| wall per turn | 10.329 s | 5.805 s | **4.724 s** |
| end-to-end | 24.09 t/s | 41.63 t/s | **48.37 t/s** |
| prefix cache hit rate | 0.0 % | 83.6–88.2 % | n/a (automatic) |

Per-turn TTFT, rep 2:

    turn        1      2      3      4      5      6      7      8     prompt 13.0K -> 16.2K
    vLLM off  4.784  4.984  5.179  5.391  5.596  5.812  6.017  6.229   climbs with depth
    vLLM on   0.401  0.254  0.119  0.309  0.498  0.695  0.185  0.384   flat, no depth trend
    lemonade  0.857  0.936  0.975  0.990  0.993  0.766  1.007  1.004   flat, mild drift

`ms/pass` — which `depth.py` documents as the quantity that is deterministic in
depth, tok/s carrying acceptance noise — across the prefix-caching arms:

| depth | PC off | PC on | delta |
|---|---|---|---|
| short control (3 workloads) | 60.56 ms | 60.69 ms | +0.2 % |
| 189 tok | 60.99 | 60.76 | -0.4 % |
| 9,479 | 75.03 | 75.02 | 0.0 % |
| 37,763 | 117.96 | 117.29 | -0.6 % |
| 69,751 | 164.90 | 165.45 | +0.3 % |

Both engines reproduced their own recorded baselines the same afternoon: vLLM
control mean 55.67 against 55.63 recorded, lemonade Q8XL 60.65 against 60.69.
Both inside 0.1%.

## What it means

Without caching, vLLM's TTFT rises **monotonically** with turn number — every
turn re-prefills a conversation that keeps growing. That is a latency pathology,
not a throughput one, and no decode benchmark on this box would have shown it.

Prefix caching costs nothing at decode. The control means say 55.67 → 54.23
tok/s (-2.6%), which looks like a real penalty and is not: `ms/pass` is flat
everywhere, and the tok/s difference is mean-accepted-length drift
(3.372 → 3.292). Same reason the deep points look *faster* with caching on
(38K 32.27 vs 31.64; 70K 22.88 vs 21.37, acceptance 3.785 vs 3.732/3.524) —
also not real. This confirms the 2026-08-22 finding ("decode unchanged, inside
noise") rather than revising it.
