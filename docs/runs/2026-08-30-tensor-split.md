---
date: 2026-08-30
subject: -sm tensor versus -sm layer on Qwen3.8-27B, with and without the MTP draft head
harness: ~/bench/tp.sh (off-repo, on the box)
box: kinoite-north
---

# Tensor split on the 27B

## What was measured

Qwen3.8-27B-UD-IQ4_XS, `-ngl 99 -c 32768`, `HIP_VISIBLE_DEVICES=0,1`, fresh load
per arm, thinking off, decode timed first-content-token to last. Shipped
`llamacpp-rocm` b1305 (llama.cpp `c745be2`, 2026-08-02).

The 4B was the wrong model to ask — tensor 106.69 vs layer 105.59, noise, on a
model small enough that layer split costs nothing.

## Numbers

| arm | rust | python | prose | MEAN | vs layer | card A | card B | pair |
|---|---|---|---|---|---|---|---|---|
| layer + MTP | 53.78 | 64.99 | 51.06 | 56.61 | — | 9099 M | 11739 M | 20838 M |
| **tensor + MTP** | 82.76 | 92.32 | 70.16 | **81.75** | **+44.4%** | 10353 M | 10353 M | 20706 M |
| layer no MTP | 30.43 | 30.41 | 30.42 | 30.42 | — | 7820 M | 8955 M | 16775 M |
| tensor no MTP | 42.20 | 42.11 | 42.11 | 42.14 | +38.5% | 8296 M | 8296 M | 16592 M |

Both layer arms reproduce the recorded baselines (56.86 and 30.40) to within
0.5%, and the MTP arm reproduces them with the same acceptance figures.

Acceptance under tensor split: 0.464, mean accepted length 2.85 —
indistinguishable from layer split's 0.448–0.476 / 2.79–2.90.

## What it means

`-sm tensor` and `--spec-type draft-mtp` compose. MTP is 1.86x on layer and
1.94x on tensor, so tensor + MTP is **2.69x** the unspeculated layer baseline.

Tensor split balances the pair exactly (10353/10353, 8296/8296) where layer
split leaves a 2.6 GB imbalance, and uses slightly less total VRAM. That balance
is the mechanism: layer split pipelines, so at batch 1 one card computes while
the other waits.

The no-MTP arms are dead flat across all three workloads — the bandwidth-bound
signature. Tensor split moves that ceiling 30.4 → 42.1, realising ~1.39x of a
theoretical 2x; the rest is the reduction.

**These are floors.** The butterfly-fallback warning fires at 27B — twice per
MTP run, once for the main model and once for the draft — so every tensor arm
ran the slow generic reduction. RCCL would presumably raise it; by how much is
unknown.

One cost specific to this combination: `-sm tensor` disables backend sampling
(`set_sampler: backend sampling not supported with SPLIT_MODE_TENSOR; using
CPU`), so the MTP draft sampler runs on the CPU under tensor split. That is
already inside the +44.4%.
