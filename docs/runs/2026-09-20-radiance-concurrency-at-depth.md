---
date: 2026-09-20
subject: "radiance concurrency at depth: why fan-out is free but not faster"
harness: ~/bench/kvdepth/concdepth2.py (off-repo, on the box), run under systemd-run against the shipped radiance quadlet on :8005; filler calibrated against the server's own /tokenize; preemption read from vllm:num_preemptions_total
box: kinoite-north
---

# Concurrency at depth on radiance

## What was measured

[runs/2026-09-15-radiance-mxfp4-dflash](2026-09-15-radiance-mxfp4-dflash.md)
measured eight concurrent streams on **short** prompts — 778 tok/s aggregate
against ~200 single-stream — and listed "concurrency at depth, and any same-day
8-way control" as not measured. That is the figure that decides how many
subagents a client may run against this box, so it is measured here.

The question is live because the client caps simultaneous subagents at 1
([decisions/2026-09-19-four-slots-and-a-client-concurrency-cap](../decisions/2026-09-19-four-slots-and-a-client-concurrency-cap.md)).
That cap was sized for lemonade, where over-subscription evicts a conversation
and pays a full reprocess to bring it back (~80 s for a 52K context). radiance
does not have fixed slots, so the cap needed re-deriving rather than carrying over.

**Setup.** The shipped `radiance.container` at its defaults on `:8005` — MXFP4,
DFlash2 at 7 draft tokens, R4D, fp8 KV, `--max-num-seqs 8`,
`--max-model-len 262144`, pinned `--kv-cache-memory 18563072000` (943,581-token
pool). Requests on loopback, not over tailnet, so the numbers are the engine's.

**Method.** N streams released together from a barrier, each with its own filler
and a 256-token generation, thinking off. The headline is **wall clock for N
tasks against N × the wall clock for one** — a speedup of 1.0 means concurrency
bought nothing. `vllm:num_preemptions_total` is differenced across each level,
because preemption is how vLLM signals pool pressure; llama.cpp's eviction has no
equivalent counter.

**Two corrections to a first attempt**, both of which invalidated it:

- The filler was assumed at ~14 tokens per line and is ~7.5, so a "45,000-token"
  prompt was really 83,670 and a "150,000" one exceeded `max_model_len` 262,144
  and returned HTTP 400. The filler is now grown against `/tokenize` until it is
  within 2% of target, as `depth.py` does.
- Stream *i* used the same seed at every level, so every level after the first
  hit the prefix cache — visible as a 0.9 s TTFT beside 20 s ones. Seeds are now
  keyed on (depth, N, i), so no prompt is ever reused.

Per-stream decode tok/s was also dropped as the headline: when prefill and decode
interleave, a stream scheduled late reports ~1 tok/s without anything being wrong.

## Numbers

Wall clock for all N streams to complete, 256 tokens generated each.

| depth/stream | N | wall | TTFT first–last | speedup vs N× serial | preemptions |
|---|---|---|---|---|---|
| ~45,000 | 1 | 9.6 s | 9.2 | 1.00x | 0 |
| | 2 | 18.8 s | 10.6 – 18.5 | 1.02x | 0 |
| | 4 | 37.5 s | 10.6 – 37.1 | 1.02x | 0 |
| | 6 | 56.6 s | 10.7 – 56.1 | 1.02x | 0 |
| | 8 | 75.3 s | 10.7 – 74.9 | 1.02x | 0 |
| ~150,000 | 1 | 41.4 s | 40.9 | 1.00x | 0 |
| | 2 | 83.9 s | 43.0 – 83.2 | 0.99x | 0 |
| | 4 | 166.2 s | 42.7 – 165.7 | 1.00x | 0 |
| | 6 | 249.3 s | 42.8 – 248.9 | 1.00x | 0 |

Prefill rate implied by the N=1 TTFT: **4,891 tok/s** at 45K and **3,667** at
150K, against 4,508 and 3,629 measured independently in
[runs/2026-09-20-prefill-and-decode-at-operating-depth](2026-09-20-prefill-and-decode-at-operating-depth.md).
The two runs agree within 8% and 1%.

## What it means

**Concurrency at depth is free, and it is not faster.** Wall clock scales
linearly with N at both depths — speedup 0.99–1.02x everywhere, with zero
preemptions. Four deep subagents finish in the same total time whether they run
together or one after another.

**The reason is that this workload is prefill-bound, and prefill is
compute-bound.** At N=1 and 45K, TTFT is 9.2 s of a 9.6 s wall: 96% of the work
is prefill. One stream already saturates the cards, so adding streams cannot add
throughput. The TTFT spread shows it directly — at N=8 the first stream starts
producing at 10.7 s and the last at 74.9 s, which is sequential service, not
parallelism.

**That is why the 09-15 short-prompt result looks so different.** Decode is
memory-bandwidth-bound and batches well, which is where 778 tok/s aggregate
against ~200 single-stream comes from. Concurrency pays in proportion to how much
of a task is decode, so it helps shallow subagents and does nothing for deep ones.

**The pool is not the constraint.** Six streams at 150K is 900,000 tokens against
a 943,581-token pool, and preemption stayed at zero throughout. The binding limit
at these depths is prefill compute, reached long before memory.

**The client cap of 1 was a llama.cpp-shaped constraint and does not transfer.**
On lemonade, over-subscription evicts and reprocesses; here it degrades to
sequential service with no thrash and no counter movement. Raising
`MAX_CONCURRENCY` against radiance is safe. It is also not a speed-up for deep
fan-out, so it should be raised for latency shape and shallow tasks, not in the
expectation that deep exploration gets faster.

**`--max-model-len` 262,144 is a hard per-request ceiling.** A prompt above it is
rejected with HTTP 400 rather than truncated — learned by overshooting it in the
first attempt.

Nothing is adopted. `MAX_CONCURRENCY` on the client is unchanged by this work, and
the shipped quadlet was not modified.

Not measured:

- **mixed depths.** Every stream at a level ran the same depth. A real fan-out
  sends subagents of different sizes, and short tasks batching behind a long
  prefill is exactly the case this design cannot see
- **prefix-cache sharing between subagents.** Seeds were made unique on purpose to
  avoid flattering the result; real subagents spawned from one conversation may
  share a large prefix, which would change the picture substantially in
  concurrency's favour
- **anything above N=8.** `--max-num-seqs` is 8; larger batches queue
- **the same sweep on lemonade**, so "radiance degrades more gracefully than
  llama.cpp" rests on the 09-19 decision record rather than a same-day control
- quality or tool-calling under concurrency. Throughput only
- repeats. One run per level
