---
date: 2026-08-30
subject: single-stream decode versus prompt depth, vLLM FP8 against llama.cpp -sm layer and -sm tensor
harness: ~/bench/depth.py and ~/bench/lemctl.py (off-repo, on the box)
box: kinoite-north
---

# Decode versus depth

## What was measured

Single stream, decode timed first-content-token to last, 512 tokens, median of 3
after a discarded warm-up, thinking off. llama.cpp with its MTP head; vLLM at
its then-shipped defaults (prefix caching still off — it does not affect decode,
see the ms/pass table in [runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md)).

The quantisation question is controlled for: Q8_K_XL is 31.5 GB against vLLM's
27.8 GB FP8, so llama.cpp reads *more* bytes per token and still wins.

## Numbers

    prompt depth    vLLM FP8      -sm layer         -sm tensor      (Q8_K_XL, 31.5 GB)
       189 tok       63.33      51.96  0.82x      77.39  1.22x
     9,479 tok       49.81      47.96  0.96x      78.58  1.58x
    37,763 tok       31.56      42.63  1.35x      62.14  1.97x
    69,751 tok       21.31      34.05  1.60x      55.67  2.61x

Concurrency, 4-way:

| | vLLM FP8 | lemonade Q8 tensor |
|---|---|---|
| short prompts, aggregate | **189.93** | 170.18 |
| deep prompts, aggregate | 60.42 | **148.38** |

## What it means

`-sm tensor` wins at every depth. `-sm layer` **loses below ~11.1K** at this
quant, which is why the split mode matters more than it looks.

The one place vLLM wins outright is 4-way short-prompt concurrency, and it loses
4-way *deep* concurrency catastrophically.
