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

## The trap is triggered — on radiance, not on the shipped vLLM

The patch that searches for the least-wasteful group size instead of `min` is no
longer hypothetical on this box. radiance ships it, and says so in its own
startup log
([runs/2026-09-19-radiance-depth-and-fp8-kv-quality](../runs/2026-09-19-radiance-depth-and-fp8-kv-quality.md)):

    [radiance] kv cache groups: size 8, 9 groups, 700 blocks/request (upstream would pick size 5)

Size 5 is exactly what the section above predicts upstream would choose for a
DFlash2 pairing, and size 8 is the least-wasteful alternative. So the trap fires
whenever radiance runs — it uses a multi-layer DFlash2 drafter — and radiance
carries its own mitigation for it. The shipped vLLM stays in the good case for
the reason given above: its 1-layer MTP head keeps the buckets at 48/17.

The two stacks report different waste from the same padding-layer count:

    shipped vLLM (MTP)   Add 3 padding layers, may waste at most  6.25%
    radiance (DFlash2)   Add 3 padding layers, may waste at most 60.00%

Three pads cost ten times as much on radiance because they land in expensive
slots, which is the same effect that made the patch outperform a naive
block-count estimate. Note that 60% is an upper bound on a specific accounting,
not a measured loss: radiance's pool is 943,581 tokens at fp8 KV, the largest on
this box. What the number establishes is that the padding mechanism is load-bearing
there and worth recording alongside any radiance pool figure — not that 60% of
radiance's cache is gone.

## A second mechanism: attention block size follows the mamba page

A different line in the same startup sequence sets the attention block size, and
it is the reason `--kv-cache-dtype fp8` does not exactly double the pool on a
hybrid model:

    radiance, bf16 KV   attention block size   832 tokens; mamba page padded 1.71%
    radiance, fp8  KV   attention block size  1648 tokens; mamba page padded 0.73%
    shipped vLLM, fp8   attention block size  1616 tokens; mamba page padded 0.62%

    "Setting attention block size to N tokens to ensure that attention page size
     is >= mamba page size."

The mamba page size is fixed — the 48 gated-delta-net layers hold constant state
and no KV — so halving the attention page size with fp8 forces the block size up
to stay matched. The constant-state share of the pool is therefore untouched by
the KV dtype, and the pool grows by less than 2x. Measured on radiance at a fixed
17.29 GiB pin: 943,581 tokens at fp8 against 509,682 at bf16, a ratio of 1.851,
from which the dtype-independent share works out at about 8% of per-token cost.
The same decomposition on the shipped vLLM at `max_model_len` 131,072 gives about
11%. Both are consistent with the logged mechanism; neither was measured directly.

The practical consequence: **do not predict a KV pool by scaling for the dtype
alone.** Read it from `GPU KV cache size` at the startup you are describing.

## If you ever benchmark a DFlash2 drafter

Record these from the **same** startup alongside tok/s:

- `Add N padding layers` from the startup log
- The reported KV-cache token count
- The drafter's exact layer count

These three numbers, together with the throughput figure, are the minimum needed
to understand whether a perceived regression is a real decode cost or just a
smaller KV pool.