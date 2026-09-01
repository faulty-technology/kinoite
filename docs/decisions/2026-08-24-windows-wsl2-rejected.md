---
date: 2026-08-24
subject: stay on native Linux dual-card rather than moving the LLM stack to Windows/WSL2
---

# Windows / WSL2 rejected

## Decision

Stay on native Linux, dual-card.

## Why

- **WSL2 has no `/dev/kfd` at all**, so the rootless Quadlets would need rework
  rather than a lift.
- **Dual-GPU is what WSL2 least reliably delivers.** ROCm-on-WSL is preview, and
  gfx1201 multi-GPU RCCL is fragile even natively (vllm-project/vllm#40980,
  ROCm/rocm-systems#5480).
- gfx1201 segfaults if the iGPU is also visible to ROCm (llamacpp-rocm#96),
  which is harder to control there.

## Findings that outlived the decision

FP8 27B is two-card-only — weights ≈27 GB fill a 32 GB card with no room for KV.
That is *why* TP=2, and it is not a Windows-specific fact.
