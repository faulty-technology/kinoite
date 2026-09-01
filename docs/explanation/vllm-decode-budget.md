# Where vLLM's decode time goes

The non-speculative baseline is 24.3 tok/s, or ~41 ms/token, and every line of
that budget is measured rather than inferred:

    FP8 GEMVs       21.5 ms   12.16 GB/rank/token at 565 GB/s effective
    all-reduce       4.5 ms   128 ops/token x 10 KiB, 35 us/op measured
    unexplained     ~15 ms
    ------------------------
    total           41.0 ms

**The hardware is not the limit.** A synthetic large read measures 587.9 GB/s,
92% of the 640 GB/s spec, and the FP8 GEMVs hit 96% of that. An external
datapoint corroborates the ceiling to within 2%: llama.cpp on a single R9700
streams this model at an implied 577 GB/s.

MTP matters precisely because it does not require explaining the ~15 ms.
Emitting ~3.0 tokens per forward pass amortises the whole budget regardless of
what it is made of. That is also why raising k pays so well here — the fixed cost
per pass is unusually large, so every extra token riding along on the same pass
is nearly free
([runs/2026-08-22-vllm-speculation-sweep](../runs/2026-08-22-vllm-speculation-sweep.md)).

Above ~40K context this ledger stops being the whole story: it is the ctx→0
intercept, and the KV term dominates exactly where agents live
([runs/2026-08-25-vllm-context-and-clocks](../runs/2026-08-25-vllm-context-and-clocks.md)).

## 4-bit is weaker than it looks for this model

The bytes actually read per token are what matter, and most 4-bit repackagings
of Qwen3.8-27B barely shrink it, because 48 of the 64 layers are Gated DeltaNet
and quantisers leave them alone:

    BF16                             55.6 GB
    FP8 (what we run)                27.8 GB
    AWQ W4A16 (barrydeen)            27.8 GB   identical to FP8; GDN kept BF16
    MXFP4 (Quark)                    23.3 GB   1.19x
    W4A16 AutoRound GPTQ             ~19.5 GB  1.43x
    GGUF IQ4_XS (llama.cpp only)     14.2 GB   1.96x

So "switch to AWQ" is a trap: same bytes, worse numerics. Only the AutoRound
W4A16 repack is worth an experiment on the vLLM side, and even then the ~15 ms
fixed cost does not shrink with it — 27.8 → 19.5 GB moves the GEMV term
21.5 → 15.1 ms, i.e. 41 → 34.6 ms, only +19% non-speculative. Stacked on k=3 it
is worth more, but it is a download and a numerics risk for maybe +15%, whereas
the k sweep was free.

## Dead ends

All eliminated by measurement on this box. Do not re-chase without new evidence:

- **NCCL_PROTO / all-reduce protocol** — comm is only 11% of the budget.
- **Context length** for the non-speculative arm — flat, see above.
- **cudagraph capture** — `CUDAGraphMode.NONE` changed nothing.
- **FP8 kernel configs** — the "Performance might be sub-optimal!" warning is
  cosmetic. The default Triton config already hits 96% of achievable, and
  kyuz0's MI300X fallback patch misses all five of this model's shapes anyway.
- **GPU clocks and thermals** — settled by a controlled A/B; +43% sclk bought
  0.0% ([runs/2026-08-25-vllm-context-and-clocks](../runs/2026-08-25-vllm-context-and-clocks.md)).
- **`gpu_memory_utilization` and `max_num_batched_tokens`** — no effect on the
  server.
- **iGPU spillover** — the iGPU holds a constant 828 MiB of desktop and never
  moves.
- **CPU saturation** — ~5 of 24 cores, and both GPUs report 100% busy
  throughout, so the CPU is not the gate.
- **Bumping to a newer stock vLLM** — 0.27.1 tested (kyuz0's own `dev` tag):
  baseline unchanged at 24.34, MTP *worse*, 34.66 vs 40.75.

That last one covers **stock version bumps only** — not the gfx1201-patched
builds (stilldeadcode/vllm-radiance, tcclaviger/vllm), which ship hand-written
kernels. Neither has been run on this box. Radiance's prefix-caching and
drafter-batch flags turned out to be flags this image already had, and both were
adopted.

Profiling note: the torch profiler records **zero** GPU kernel events in this
image — kineto's ROCm activity backend produces nothing, with or without
cudagraphs — and `rocprofv3` only flushes at process exit while vLLM will not
exit under it. `rocprofv3` is present if you want to retry, but budget real time
for it. The working approach was micro-benchmarking kernels directly against a
measured bandwidth ceiling.

## The upstream TP=2 hang, and why this box is a counter-example

Two open upstream reports describe a hard TP=2 deadlock on exactly this
hardware — both R9700s pinned at 100% with no requests in flight, inference
never returning, TP=1 fine:

    vllm-project/vllm#40980     kyuz0, 2026-04-27   open, bug/rocm, assigned to an
                                AMD engineer, project status "In Progress"
    ROCm/rocm-systems#5480      kyuz0, 2026-04-27   open, "status: triage",
                                assigned tcgu-amd, no AMD reply on the thread

Both say the same thing about the cause: RCCL **2.27.3 works, 2.27.7 hangs** — a
regression between two RCCL builds, not a vLLM bug. `NCCL_P2P_DISABLE=1` and
`--enforce-eager` are recorded as not helping.

**We do not have this bug**, and the reason is worth writing down because it is
the only real datum anyone has on the other side:

    :latest (2026-06-13, vLLM 0.22.1rc1.dev499)                RCCL 2.29.7   <- what we serve on
    :dev == :rocm7.14.0-torch2.11.0-vllm0.27.1 (2026-08-12)     RCCL 2.30.4

This box has served TP=2 continuously since 2026-08-16 on RCCL 2.29.7 — two
minor versions past the one those issues call broken. That is a counter-example
neither issue has, and it means the hang is version- or config-specific rather
than a property of gfx1201 TP=2. It does **not** mean 2.27.7 was misdiagnosed;
we never ran 2.27.7.

What it costs: an image bump moves RCCL as a side effect, and nobody — not us,
not either issue — has data on 2.30.4. Hence the third condition on the
image-bump rule: post-07-04 fix, **and** not a decode regression, **and** does
not reintroduce the TP=2 hang. Verify the third by starting the candidate at
TP=2 and watching for the deadlock signature (both cards at 100%, no tokens)
*before* benchmarking anything, because a deadlocked engine looks like a slow one
until you check `rocm-smi`.
