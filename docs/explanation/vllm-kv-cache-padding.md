# vLLM KV-cache group padding — why it happens, and the DFlash2 trap

The startup log shows a warning that looks like a misconfiguration:

    WARNING kv_cache_utils.py:1174 Add 3 padding layers, may waste at most 6.25% KV cache memory

It is not an error, and for the current MTP drafter it is already optimal.

## Why padding happens

vLLM slices layers into equal-size groups for KV-cache management. Any bucket
that does not divide evenly into the group size gets padded with placeholder
layers that still receive real memory allocations. Group size is the **smallest**
bucket (upstream picks `min` over the buckets — the FIXME in `kv_cache_utils.py`
acknowledges it is the wrong strategy for complex patterns).

## Current split: MTP, already optimal

This box runs Qwen/Qwen3.8-27B-FP8, a hybrid model (`qwen3_5`):

    48  gated-delta-net layers (linear attention, constant state — no growing KV)
    16  full-attention layers (standard attention, growing KV per token)
     1  MTP draft head, merged into the full-attention bucket
    --
    65  real layers

Buckets: 48 GDN + 17 full-attn. `min = 17`, so group size is 17:

    4 groups × 17 = 68 slots for 65 real layers = 3 padding
    3 / 48 = 6.25% — exactly the warning

Group size 17 is provably optimal under the constraint that matters (never more
groups than today). Raising it wastes more:

    group size   groups   slots   waste
    17           4        68      3      <- current, optimal
    18           3 → 4    72      7
    24           3        72      7
    48           2        96      31

Zero waste needs a group size dividing both 48 and 17 — `gcd(48, 17) = 1`, so
that means 65 groups of 1, which is absurd. Even a perfect upstream patch
(e.g., searching for the least-wasteful group size instead of `min`) is worth at
most the 3 padding slots — ~4% of the pool (~10K of the ~225K tokens at 0.80
`gpu_memory_utilization`).

## The DFlash2 trap

A multi-layer DFlash2-style drafter forms a **third** bucket and collapses the
group size to its own layer count. At 5 layers:

    buckets: 48 GDN / 16 full-attn / 5 drafter
    min = 5, group size = 5
    48 → 50 (10 groups), 16 → 20 (4 groups): 14 groups × 5 → wait, actually:

    48 / 5 = 9.6 → 10 groups → 50 slots
    16 / 5 = 3.2 →  4 groups → 20 slots
     5 / 5 = 1       →  1 group  →  5 slots
    --
    15 groups × 5 = 75 slots for 69 layers (65 + 5 drafter − 1 MTP replaced)
    ~8% wasted

So adopting a DFlash2 drafter does not just trade acceptance rate for draft
compute cost — it **silently changes how much of the KV pool is real**. A
drafter whose layer count divides evenly into 48 **and** 16 (i.e., 4 or 8
layers) costs nothing. A 5- or 7-layer drafter shrinks the usable pool even
before counting per-request round-ups.

An upstream patch that searches for the least-wasteful group size instead of
`min` (their buckets → size 8, 9 groups, 72 slots) reportedly reclaimed ~21% of
KV on a DFlash2-like pairing (evaluated against this repo 2026-08-27; the pads
sat in expensive full-attention slots, which is why it outperforms the naive
4.2% block-count estimate). None of it applies here — the current 1-layer MTP
head is the reason this box stays in the good case.

## If you ever benchmark a DFlash2 drafter

Record these from the **same** startup alongside tok/s:

- `Add N padding layers` from the startup log
- The reported KV-cache token count
- The drafter's exact layer count

These three numbers, together with the throughput figure, are the minimum needed
to understand whether a perceived regression is a real decode cost or just a
smaller KV pool.