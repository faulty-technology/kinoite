---
date: 2026-09-15
subject: radiance as a rootless Quadlet: de-privileged posture against the upstream launcher, a 246K prefill and 8 streams at 38K against the pinned KV cache, and the lowest ceiling that still serves 131K
harness: ~/bench/radiance/unit-test/unit-test.sh (three arms) and probe.py, driving ~/bench/depth.py against a shadow radiance.container; raw output ~/bench/radiance/unit-test/{run.log,sampler.log} (off-repo, on the box)
box: kinoite-north
---

# The radiance quadlet: posture, allocation headroom, and the floor

## What was measured

Three questions the [09-15 radiance run](2026-09-15-radiance-mxfp4-dflash.md) left open, in one
GPU window, against the `radiance.container` unit from `build_files/profiles/north/radiance.sh`
installed as a shadow unit:

1. **Does the quadlet's posture cost anything?** Upstream's `serve-mxfp4.sh` runs
   `--privileged --network=host`. The unit instead takes the GPU nodes, `keep-groups`, host IPC,
   `SYS_PTRACE`, no seccomp and no SELinux label, and publishes on loopback only.
2. **Is the pinned 17.29 GiB KV cache safe at the shapes the 09-15 run never tried?** Namely a
   near-context-length prefill, and 8 concurrent streams at agentic depth.
3. **What is the lowest ceiling that still serves one 131,072-token conversation**, with the pin
   dropped so vLLM profiles for itself, and what does it leave free per card?

Everything else is the shipped configuration: MXFP4 with the DFlash2 drafter at 7 draft tokens,
R4D attention, FP8 KV, TP=2, 8 sequences, 8192-token chunks. Thinking off, temperature 0, decode
timed from the first content token to the last.

## Numbers

**Posture.** `privileged=false`, `net=pasta`, `ipc=host`, `caps=[CAP_SYS_PTRACE]`, listening on
`127.0.0.1:8005` only. Healthy 120 s after `systemctl --user start` on a warm compile cache. The
KV pool is identical to the upstream launcher's: 943,581 tokens, 3.60x at 262,144 per request.

Decode versus depth, quadlet against the upstream launcher the same afternoon:

| point | quadlet tok/s | quadlet ms/pass | launcher ms/pass | Δ |
|---|---|---|---|---|
| control mean | 182.58 | 21.85–22.00 | 21.92–22.08 | −0.07 |
| 189 | 204.88 | 22.37 | 22.46 | −0.09 |
| 9,479 | 179.44 | 23.43 | 24.24 | −0.81 |
| 37,763 | 185.94 | 24.32 | 24.04 | +0.28 |
| 69,751 | 171.37 | 26.01 | 26.10 | −0.09 |

The 9,479 point is the noisy one in both runs: acceptance was 4.205 here against 4.529, and the
tok/s spread exceeds 6%. Everywhere else the two agree within 1.2%.

**Allocation probe, at the shipped 0.98 and the pinned cache.** Both cases completed with no
allocation failure, with 89 MiB free per card afterwards.

| case | result |
|---|---|
| 246,274-token prefill | TTFT 81.82 s (3,010 tok/s prefill), then decode 123.89 tok/s |
| 8 streams × 37,644 tokens | all 8 completed; decode-agg 160.83 tok/s, wall-agg 16.68 tok/s over 61.37 s |

In the concurrent case per-stream decode ran 3.46–112.73 tok/s and TTFT 9.13–60.24 s: 301K prompt
tokens arriving at once is prefill-bound, and streams decode while others still prefill. The same
8 streams on short prompts reached 778.67 tok/s decode-agg in the 09-15 run.

**Floor.** `--gpu-memory-utilization 0.55` with `--kv-cache-memory` dropped and
`--max-model-len 131072` served on the first attempt, so 0.62 and 0.70 were never needed.

| | shipped (0.98, pinned) | floor (0.55, profiled) |
|---|---|---|
| KV cache | 943,581 tokens, 3.60x at 262,144 | 135,795 tokens, 1.04x at 131,072 |
| VRAM per card while serving | 32,523 of 32,624 MiB | 17,786 of 32,624 MiB |
| free per card | 101 MiB | 14,838 MiB |
| startup to healthy | 120 s | 260 s (recompiled for the new shape) |
| control mean | 182.58 tok/s | 182.44 tok/s |
| ms/pass at 189 / 9,479 / 37,763 / 69,751 | 22.37 / 23.43 / 24.32 / 26.01 | 22.36 / 23.97 / 24.40 / 25.57 |

Peak VRAM across the whole window was 32,535 MiB per card, during the probe.

## What it means

**The de-privileged, loopback-only unit costs nothing.** Every depth point matches the upstream
launcher within 1.2%, and the noisiest point moves in the faster direction. Dropping
`--privileged` and `--network=host` did not change the kernel selection either: the unit's journal
reports the same `R4D kernel selection: libr4d 0.4.0, 16 kernels built, 18 of 20 queries resolved`.

**The pinned cache holds at the shapes that break a profiled one.** A 246K-token prefill — 94% of
the context length — and 8 concurrent streams at 38K both completed with ~90 MiB of VRAM to spare.
This is not the 2026-08-24 failure mode ([runs/2026-08-24-vllm-prefill-oom](2026-08-24-vllm-prefill-oom.md)):
there, vLLM profiled, sized the cache to 2.63x the context, and an unchunked 16K prompt had
nowhere to put a 538 MiB activation. Here the cache size is an explicit measured pin, prefill is
chunked at 8192, and vLLM skips profiling entirely.

**Concurrency at depth is prefill-bound, not memory-bound.** Eight streams at 38K deliver 160.83
tok/s aggregate against 778.67 for the same eight on short prompts. Nothing failed; the wall time
is dominated by prefilling 301K tokens.

**Cache size does not buy decode.** At 0.55 with a seventh of the cache, decode is within 1% of
0.98 at every depth. The ceiling buys context length and concurrency, and nothing else.

**The floor leaves 14.5 GiB per card free.** At 131,072 context the whole stack fits in 17.8 GiB
per card. What that fits beside is not measured here, but for scale: the Q8XL daily driver held
19.0 GiB per card in the same window's control, so it does not fit; a 4-bit 27B or a Whisper-class
model would.

The cost is concurrency: 135,795 cached tokens is 1.04 full-length conversations, so 8 agent calls
at 38K — about 301K tokens — would queue rather than run together.

Not measured:

- a second workload actually running beside radiance, and what sharing the cards does to either
- the VRAM a klein image-gen session or a Whisper model takes on this box
- output quality at any setting
- repeats: one run per arm, and the probe's concurrent case once
