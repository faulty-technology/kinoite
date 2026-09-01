---
date: 2026-08-30
subject: IQ4_XS, Q6_K_XL and Q8_K_XL on Qwen3.8-27B, decode versus depth and concurrency
harness: ~/bench/q6-suite.sh, raw output ~/bench/q6-results.txt (off-repo, on the box)
box: kinoite-north
---

# Three-quant sweep

## What was measured

Q6_K_XL on the identical harness, identical MTP draft head and identical depths
as the earlier IQ4_XS and Q8_K_XL runs, so all three are one-variable
comparisons. Single stream, `-c 98304`, `-np 1`, decode timed
first-content-token to last.

## Numbers

| depth | IQ4_XS 14.0 GB | **Q6_K_XL 25.3 GB** | Q8_K_XL 31.5 GB | vLLM FP8 27.8 GB |
|---|---|---|---|---|
| control mean, tensor | 82.80 | **65.53** | 65.91 | 55.63 |
| control mean, layer | 55.96 | **45.22** | 42.21 | 55.63 |
| short (189), tensor | 92.41 | **80.19** | 77.39 | 63.33 |
| short (189), layer | 69.66 | **54.16** | 51.96 | 63.33 |
| 9K, tensor | 80.21 | **72.58** | 78.58 | 49.81 |
| 9K, layer | 61.52 | **52.57** | 47.96 | 49.81 |
| 38K, tensor | 71.75 | **60.67** | 62.14 | 31.56 |
| 38K, layer | 48.05 | **40.89** | 42.63 | 31.56 |
| 70K, tensor | 67.83 | **54.31** | 55.67 | 34.05 (layer) / 21.31 vLLM |
| 70K, layer | 43.54 | **34.20** | 34.05 | 21.31 |

ms/pass decomposition:

| arm | slope (ms per 1K ctx) | intercept (ms) | weights |
|---|---|---|---|
| IQ4_XS tensor | 0.2045 | 41.04 | 14.0 GB |
| **Q6_K_XL tensor** | **0.2057** | **49.72** | 25.3 GB |
| Q8_K_XL tensor | 0.1971 | 49.48 | 31.5 GB |
| IQ4_XS layer | 0.4149 | 56.56 | 14.0 GB |
| **Q6_K_XL layer** | **0.4068** | **71.92** | 25.3 GB |
| Q8_K_XL layer | 0.3972 | 73.21 | 31.5 GB |

Concurrency (4 slots; short = `-c 32768`, deep = 4 x 38K at `-c 196608`):

| arm | 4x short, aggregate | 4 x 38K, decode-agg |
|---|---|---|
| IQ4_XS tensor | 178.27 | 161.03 |
| **Q6_K_XL tensor** | **162.99** | **144.77** |
| Q8_K_XL tensor | 170.18 | 148.38 |
| IQ4_XS layer | 134.47 | 101.96 |
| **Q6_K_XL layer** | **118.70** | **90.15** |
| Q8_K_XL layer | 126.71 | 93.03 |
| vLLM FP8 | **189.93** | 60.42 |

VRAM, pair figures for Q6_K_XL with the MTP head:

| config | tensor | layer |
|---|---|---|
| `-c 98304 -np 1` | 16535 / 16536 MiB | 15113 / 18751 MiB |
| `-c 196608 -np 4` | 20896 / 20896 MiB | 19158 / 22828 MiB |

Those two points scale to **0.0444 MiB/token/card** under tensor split, with a
fixed (weights + non-KV) term of **12174 MiB/card**. The estimate is
deliberately conservative: the `-c 196608` point had 4 slots against the
`-c 98304` point's 1, so slot-count overhead is folded into the slope rather
than netted out.

## What it means

**Q6 lands on Q8, not between Q8 and IQ4.** 25.3 GB and 31.5 GB of weights
decode at the same rate to within noise, while 14.0 GB is 26% faster. Decode on
this box is not proportional to weight bytes.

The ms/pass decomposition says why, for the third time. Slope — the context/KV
term — is constant across all three quants, KV being f16 regardless. The
INTERCEPT, the weight term, is *also* flat between Q6 and Q8 and only drops at
IQ4: a 2.21x change in weight bytes (IQ4 → Q8) moves it 21%, and the 1.24x from
Q6 → Q8 moves it 0%. The large fixed per-pass cost — butterfly reduction, CPU
draft sampler, launch overhead — dominates.

Against vLLM at Q6: tensor split wins at every depth (1.27x short, 1.46x at 9K,
1.92x at 38K, 2.55x at 70K), while **layer split loses below roughly 6–7K
context** (0.86x at 189 tokens, 1.06x at 9.5K) and only pulls ahead deeper. The
Q8 crossover was ~11.1K, so Q6 moves it down but does not remove it — and short
prompts are exactly what an agentic loop's first turns look like.

The seeded `ctx_size` values follow from the VRAM scaling: 131072 → ~17.9
GB/card (14 GB headroom on a 32 GB card), 262144 → ~23.8 GB/card. Both fit, so
`--fit` being unavailable under SPLIT_MODE_TENSOR is not a blocker for the Q6
seeds.
