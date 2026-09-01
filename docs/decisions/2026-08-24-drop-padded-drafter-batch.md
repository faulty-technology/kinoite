---
date: 2026-08-24
subject: drop disable_padded_drafter_batch and keep --max-num-seqs 4
---

# Drop the drafter-batch flag, keep concurrency

## Decision

`disable_padded_drafter_batch` is removed from `VLLM_SPECULATIVE`, so upstream's
`false` applies. `--max-num-seqs` stays at 4.

## Why

The flag crashes the engine at n>=3 concurrent requests
([runs/2026-08-24-drafter-batch-concurrency-crash](../runs/2026-08-24-drafter-batch-concurrency-crash.md)).

## The alternative, and why it was rejected

Keep the flag and cap concurrency at the tested-safe `VLLM_MAX_SEQS=2`.

Rejected deliberately. Concurrency is worth more here than 19.1% of
single-stream decode: the box exists to serve parallel agent tool calls, which is
why `--max-num-seqs 4` was chosen in the first place.

**This is a settled choice, not a default nobody looked at.** Do not restore the
flag on the strength of the 2026-08-22 throughput table alone — that table is
single-stream and cannot see the failure.

If you do want the trade back, it is both lines together or neither:

    Environment='VLLM_SPECULATIVE={"method":"mtp","num_speculative_tokens":3,"disable_padded_drafter_batch":true}'
    Environment=VLLM_MAX_SEQS=2

## What was given up

+19.1% decode (64.54 vs 54.21 tok/s mean). Acceptance length was unchanged
(3.006 vs 3.020), so it was never better speculation — just per-forward-pass
padding overhead removed. Biggest gain on the weakest workload: prose 48.90 →
62.16 (+27%).

## Loose end

The flag was coupled to `--no-async-scheduling` (upstream requires the pairing;
the flag alone was never tested). With the flag gone that coupling no longer
applies, and `--no-async-scheduling` costs 3.2% by itself (52.48 vs 54.21,
measured as its own arm).

So there is likely ~3% sitting there for whoever re-tests async scheduling with
plain MTP. Untested, hence left as-is — it is still applied whenever speculation
is on, which is the conservative choice, not a measured one.
