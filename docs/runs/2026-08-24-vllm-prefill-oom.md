---
date: 2026-08-24
subject: VRAM OOM on a single unchunked prefill step, and the per-card memory ledger behind it
harness: diagnosed from the journal and dump_input after a live failure
box: kinoite-north
---

# The prefill OOM

## What was measured

A 16,146-token prompt arrived and the scheduler put the whole thing in **one**
prefill step — `dump_input` showed `total_num_scheduled_tokens=16146`, under the
then-16384 budget — so "chunked prefill is enabled" chunked nothing.

## Numbers

Both TP ranks died in `w8a8_triton_block_scaled_mm` allocating that step's bf16
GEMM output, 16146 x 17472 x 2B = 538.00 MiB exactly:

    torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 538.00 MiB.
    GPU 1 has a total capacity of 31.86 GiB of which 0 bytes is free.

Per-card ledger at the time:

| | GiB |
|---|---|
| weights | 14.68 |
| KV | 10.96 |
| graph capture | 0.81 |
| non-torch (HIP ctx, RCCL, hipBLASLt/triton) | ~4.12 |
| **total** | **~30.6 of 31.86** |

Leaving ~1.3 GiB for the whole prefill activation set. The KV cache was 8% used.

After dropping `--max-num-batched-tokens` to 8192: largest prefill buffer ~269
MiB, KV grew 10.96 → 12.01 GiB (308,317 → 344,064 tokens), measured idle
28.5 GiB/card. A 16,030-token prompt — the size that OOMed — answers in 7 s.

## What it means

This was **not** context length or concurrency. It was one oversized prefill
step.

**The 64 GB pool does not help.** TP=2 shards weights, KV and activations per
card; it does not pool them. The binding constraint is always one card's
31.86 GiB, and the ~4.1 GiB of non-torch overhead is *duplicated* per rank
rather than shared.

Halving the budget does not by itself buy much headroom: vLLM profiles at
`max_num_batched_tokens` and hands whatever is left to the KV cache, so lowering
it mostly moved memory into KV — call it ~1–2 GiB gained. **The real win is that
the peak step is half the size**, not the headroom.

For a bigger guaranteed margin the lever is `VLLM_GPU_UTIL` (0.95 → 0.90,
~1.6 GiB/card that KV cannot reclaim); concurrency is 2.62x the 128K context
against `--max-num-seqs 4`, so there is plenty to give back. Also unset and
worth a try: `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`, which targets
the 786 MiB reserved-but-unallocated (fragmentation) at the moment of the OOM.
