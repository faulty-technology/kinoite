---
date: 2026-08-30
subject: peer-to-peer bandwidth between the two R9700s and the iGPU
harness: rocm-bandwidth-test 2.6.0, via the startup sweep in stilldeadcode/vllm-radiance:0.9.3
box: kinoite-north
---

# P2P bandwidth across the pair

## What was measured

`stilldeadcode/vllm-radiance:0.9.3` run by hand purely for its startup
`RADIANCE_RUN_BWTEST` sweep, killed before the model loaded.

## Numbers

    Device: 0  AMD Ryzen 9 9900X          Device: 1  R9700  03:0.0
    Device: 3  AMD Radeon Graphics 10:0.0 Device: 2  R9700  06:0.0

    NUMA distance      CPU<->GPU 20      GPU<->GPU 40      (single NUMA node)

    Unidirectional peak GB/s        Bidirectional peak GB/s
       1 <-> 2   28.158 / 28.156       1 <-> 2   55.642
       0 <-> 1   28.772 / 28.157       0 <-> 1   50.729
       1 -> 1   483.284 (on-card)      3 <-> 1/2 35.560 / 35.296
       2 -> 2   531.850 (on-card)

Radiance's banner reports `P2P access : ENABLED 0<->1`, and Inter-Device Access
is 1 for every pair, iGPU included.

The iGPU is markedly slower to both dGPUs: 17.8 GB/s.

## What it means

**The number that matters is 28.2 GB/s: a peer copy between the two R9700s is
exactly as fast as a copy to host memory.** There is no direct link. P2P here
means "the driver will let you DMA card to card over PCIe", not "there is a
faster path".

So P2P being available does not change the arithmetic that already said comm is
~11% of the token budget; it removes a host bounce, nothing more.
`GGML_CUDA_P2P=1` is safe to try — access is genuinely enabled and no IOMMU
kargs are set on this box — but changed nothing observable in the tensor-split
runs of the same day.

The on-card copy figures (483 / 532 GB/s) are copy bandwidth, read+write, not
the ~588 GB/s synthetic large-read figure recorded under vLLM. Do not compare
them directly.
