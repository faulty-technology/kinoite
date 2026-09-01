---
date: 2026-08-24
subject: disable_padded_drafter_batch crashes the vLLM engine under concurrency
harness: four parallel 16K-token prompts, bisected on the box
box: kinoite-north
---

# The drafter-batch flag crashes under concurrency

## What was measured

Four parallel 16K-token prompts against the running server, bisected by
concurrency level.

## Numbers

    TRUE : n=2 OK | n=3 CRASH (4 assertions) | n=4 CRASH
    FALSE: n=4 OK, 12/12 across three rounds, 0 assertions, 0 restarts

The drafter dies preparing a batched step:

    vllm/v1/spec_decode/llm_base_proposer.py:1082 in prepare_inputs
    assert common_attn_metadata.seq_lens_cpu_upper_bound is not None   -> AssertionError

That takes EngineCore with it, so every in-flight request 500s and the server
exits.

## What it means

The flag was incompatible with the concurrency this same launcher configures —
`--max-num-seqs` is 4.

The 2026-08-22 benchmark that adopted it never caught this because every arm was
measured **single-stream**
([runs/2026-08-22-vllm-speculation-sweep](2026-08-22-vllm-speculation-sweep.md)).
A throughput harness that does not exercise concurrency cannot clear a flag that
only fails under it.
