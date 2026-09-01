---
date: 2026-08-31
subject: prompt:generated ratio from server counters on real traffic, lemonade vs vLLM
harness: llamacpp Prometheus counters and vLLM journal windows — no benchmark
box: kinoite-north
---

# What the journals say about real use

## What was measured

Server-side counters and logs from actual traffic, independent of any benchmark.
This is what prompted the investigation, and it is the strongest evidence
because nobody was benchmarking when it was produced.

## Numbers

**lemonade Q8XL**, `llamacpp:*` Prometheus counters, one 51-minute session
(`--ctx-size 131072`, `-sm tensor -fa on --spec-type draft-mtp
--spec-draft-n-max 3`):

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

Amortised per output token:

| | prefill | decode | total | effective |
|---|---|---|---|---|
| vLLM FP8 (PC off, as it ran) | 20.14 ms | 43.31 ms | 63.45 ms | 15.76 t/s |
| lemonade Q8XL | 4.46 ms | 33.90 ms | 38.36 ms | 26.07 t/s |

## What it means

The 12x prompt:generated ratio difference is the finding. vLLM was re-prefilling
27.3 prompt tokens per generated token against llama.cpp's 2.29 — and llama.cpp
reached a *deeper* context (110,926 tokens) while doing it, so this is not a
workload artifact. vLLM spent 343 minutes prefilling against 642 minutes
decoding.

Caveat kept deliberately: the lemonade sample is 51 minutes of one workload,
vLLM's is two weeks of mixed use. The decode figures are robust on both sides
(thousands of samples), the ratio is partly workload — but 12x is far too large
to be anything but the cache.
