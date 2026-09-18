---
date: 2026-09-18
subject: "q8_0 KV cache and slot count on the Q8XL daily driver: prefix-cache eviction, VRAM, decode at depth"
harness: journal mining of `journalctl --user -u lemonade` for slot selection, timings and VRAM; ~/bench/kvquant-deep.py (183K log-filler prompt with a planted retrieval fact, single stream) and ~/bench/kvquant-short.py (25-token control), both off-repo on the box; peak VRAM sampled from /sys/class/drm/card*/device/mem_info_vram_used at 3 s during each load
box: kinoite-north
---

# q8_0 KV cache and slot count on the Q8XL daily driver

## What was measured

Started from a complaint that long agent sessions were losing their prefix
cache "on idle". They were not. The journal for the 2026-09-18 boot (12:52
onward, 8.1 h, 383 completions, all `Qwen3.8-27B-Q8XL`) shows the cause is LRU
eviction from an oversubscribed unified pool, and the idle timer is a separate
and harmless mechanism.

`--parallel 4 --kv-unified` with `ctx_size` 262144 was baked on the strength of
[runs/2026-09-18-lemonade-parallel-slots](2026-09-18-lemonade-parallel-slots.md).
That run's pool semantics and VRAM arithmetic hold. Its slot-count conclusion
does not, and is superseded here.

**Checkpoint geometry.** Read from the GGUF metadata, because it decides how
much a cache flag can buy. `qwen35`, `block_count` 65,
`full_attention_interval` 4: 17 blocks carry `attn_k`/`attn_v` (indices 3, 7,
11 … 63, 64) and the other 48 are SSM blocks whose state no cache flag touches.
`head_count_kv` 4, `key_length` and `value_length` 256. So the pool costs
68.0 KiB/token at f16 and 36.1 at q8_0, not the 2x of a dense model's whole
stack.

**Arms.** Five, as hand-added recipes alongside the shipped one, all the same
`4ca7207` Q8_K_XL weights with `-sm tensor -fa on`, the Q4_0 MTP drafter and the
`medium` reasoning pin. One 183,211-token prompt, temperature 0, 300 max tokens,
with a vault code planted at token ~50 and read back as a retrieval check.

## Numbers

Prefix-cache behaviour over the 8.1 h window:

| | count |
|---|---|
| slot selected by LCP similarity (cache hit) | 330 |
| slot selected by LRU (cache miss, full reprocess) | 56 |
| requests arriving with aggregate demand over the 262,144 pool | 132 / 362 |

Aggregate demand is the sum of the other slots' last-known conversation lengths
plus the incoming one. Its median was 237,144 against a 262,144 pool, and its
peak 565,657 — 2.16x the pool, with one slot at 224,304 while the others held
341,353. Eleven requests deeper than 100K tokens paid more than 60 s of TTFT
each, 35.0 minutes in total; the worst was 289.8 s to reprocess 171,886 tokens
for 103 tokens of output. Prefill across all 383 requests was 53.5 minutes.

Concurrency over the same window, by wall time:

| slots busy | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| share of 8.1 h | 63.8% | 31.9% | 2.5% | 0.9% | 1.0% |

Decode over the window: median 48.9 tok/s, p10 30.0, p90 64.5. MTP acceptance
aggregate 0.6791 (257,456 accepted / 379,114 generated), mean draft length 3.21.

The five arms, single stream at 183,211 tokens:

| arm | peak card 1 | peak card 2 | prefill tok/s | decode tok/s | acc | retrieval |
|---|---|---|---|---|---|---|
| f16, pool 262144 (shipped) | 27,146 | 26,031 | 865.9 | 46.75 | 0.804 | pass |
| q8_0 V only, pool 262144 | 25,674 | 24,560 | 858.2 | 44.90 | 0.845 | pass |
| q8_0 K+V, pool 262144 | 24,271 | 23,156 | 847.9 | 41.23 | 0.845 | pass |
| q8_0 K+V, pool 393216 | 27,469 | 26,356 | 848.6 | 40.91 | 0.845 | pass |
| q8_0 K+V, pool 524288 | 30,668 | 29,553 | 848.2 | 40.92 | 0.845 | pass |

MiB of 32,624 per card. The f16 arm reproduces the 26,964 / 25,828 recorded in
the parallel-slots run, so the sampling method matches.

On a 25-token control prompt, 190 tokens generated, the same arms sit at 83.67 /
83.78 / 83.80 tok/s (f16) against 82.47 (q8_0 K+V, pool 262144) and 81.38–82.15
(q8_0 K+V, pool 524288), all at draft acceptance 0.973. The quantisation cost is
invisible at that depth and only appears once the cache is large.

Pool size does not affect single-stream decode: 41.23, 40.91 and 40.92 tok/s at
262144, 393216 and 524288.

`n_ctx_slot` stays 262144 at every pool larger than it, with
`llama_context: n_ctx_seq (393216) > n_ctx_train (262144) -- possible training
context overflow` logged once per load. The only other warning is
`set_sampler: backend sampling not supported with SPLIT_MODE_TENSOR; using CPU`,
which the f16 arm logs too.

The idle timer, 17 firings in the window:

| | count |
|---|---|
| fired with a request in flight | 11 / 17 |
| followed by a cache hit on the next slot selection | 13 / 17 |

Several of those hits were `f_sim_best = 1.000` within a second of the downsize,
including one that fired 0.12 s after a completion. `Downsizing model by erasing
KV cache` releases unused allocation; it does not drop conversation prefixes,
and its 60 s window is a different knob from the recipe's
`evict_idle_timeout` of 1800.

## What it means

**The eviction is pool pressure, not idleness.** LRU picks the least recently
used slot, which is the session the operator stepped away from, so it presents
as an idle timeout. The trigger is another session needing the cells. This is
why it fires in the middle of active work.

**q8_0 costs 12% of decode at depth on this box.** 46.75 to 41.23 tok/s,
reproduced three times across two pool sizes. Draft acceptance rises rather than
falls (0.804 to 0.845) and the planted fact is retrieved in every arm, so the
loss is dequantisation cost in the attention kernel, not a speculation or
quality regression. Splitting the halves: V alone costs 4%, K the remaining 8%.
The expensive half is also the one carrying post-RoPE precision at
`rope.freq_base` 10,000,000.

**Quantising without enlarging the pool is strictly worse than not quantising.**
Eviction is bounded by cell count, not by VRAM, so q8_0 at the same 262144 pays
the full 12% and prevents nothing. The 2.9 GiB per card it frees is only worth
having if it is spent on cells.

**Spent on cells, it does not pay for itself here either.** q8_0 K+V at 393216
lands at 27,469 / 26,356 MiB, the same headroom the shipped f16 pool has, and
holds two ~170K sessions where 262144 held one. Against that, 12% of roughly
122 minutes of decode in the measured window is ~15 minutes, versus the 35
minutes of reprocessing TTFT it would avoid. A ~20 minute net over 8 hours, for
a permanent throughput cut and a pool that still cannot hold the 565K peak.
524288 is a further 1.5 GiB per card past the point where the margin (1,956 MiB)
is worth defending, and the failure mode for exceeding a pool is killing live
streams after prefill.

**Two slots instead of four is the cheaper fix.** A retained slot holds its
conversation's cache whether or not it is generating, so four deep sessions
oversubscribe 262144 continuously, while three or more streams are live under 2%
of busy wall time. Halving the slots halves the competition at no decode cost and
no VRAM cost. `--parallel 2 --kv-unified` at `ctx_size` 262144 with f16 KV is
baked on `user.Qwen3.8-27B-Q8XL`; `--kv-unified` stays, because static partition
would cap each slot at 131072, under this box's working depth.

No KV cache quantisation is shipped on any recipe.
