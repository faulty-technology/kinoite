# Why `-sm tensor`, and what it costs

llama.cpp's tensor split is the single largest decode lever on this box: +44.4%
on the 27B with the MTP head, and the difference between beating vLLM everywhere
and losing to it on short prompts
([runs/2026-08-30-tensor-split](../runs/2026-08-30-tensor-split.md),
[runs/2026-08-30-quant-sweep](../runs/2026-08-30-quant-sweep.md)).

## `-sm row` is dead and that no longer matters

Upstream deprecated `row` — it split only dense weights — and replaced it with
`tensor`, which splits weights *and* KV. On b1305, `-sm row` still exits with
`device ROCm0 does not support split buffers`. Stop citing it as the ceiling.

`-sm tensor` loads, serves, and generates text byte-identical to `-sm layer` at
temperature 0. The documented architecture gate never fired: the string
*"LLAMA_SPLIT_MODE_TENSOR not implemented for architecture '...'"* did not
appear, and `qwen35` is not on upstream's exclusion list (which does name Jamba,
Falcon-H1, Kimi-Linear, Nemotron-H, Mamba).

## Why it wins

Tensor split balances the pair exactly where layer split leaves a 2.6 GB
imbalance. That balance *is* the mechanism: layer split pipelines, so at batch 1
one card computes while the other waits.

It composes with speculation. MTP is 1.86x on layer and 1.94x on tensor, so
tensor + MTP is 2.69x the unspeculated layer baseline, with acceptance
indistinguishable between the two split modes.

## Four conditions, each measured

1. **`-fa on` is mandatory.** `-fa off` gives `SPLIT_MODE_TENSOR requires
   flash_attn to be enabled`. Incidentally the first hard evidence that flash
   attention works on gfx1201 in this build.
2. **The iGPU must be excluded**, and `-dev` alone is not enough once a draft
   model is in play. See
   [reference/gpu-topology](../reference/gpu-topology.md#the-igpu-must-be-excluded-from-rocm-workloads).
3. **`--fit` is unsupported** — `llama_params_fit is not implemented for
   SPLIT_MODE_TENSOR, abort`. It is a warning and the load continues, but `-c`
   has to be sized by hand. The VRAM scaling in
   [runs/2026-08-30-quant-sweep](../runs/2026-08-30-quant-sweep.md) is what
   replaces it.
4. **Backend sampling is disabled**, so the MTP draft sampler runs on the CPU
   under tensor split. Already inside the measured +44.4%.

## The RCCL ceiling

Every run logs `internal AllReduce init failed (n_devices != 2?); falling back
to meta-backend butterfly` **even with exactly two devices**, because RCCL is a
build-time opt-in (`-DGGML_HIP_RCCL=ON`) that upstream leaves off and this build
does not set.

Verified three ways in the shipped bundle: no `librccl*` file, no RCCL in `ldd
libggml-hip.so`, no RCCL symbols in `nm -D`. There is a runtime selector,
`GGML_CUDA_ALLREDUCE`, and `internal`/`nccl` are genuinely accepted values — a
bogus one logs `unknown GGML_CUDA_ALLREDUCE value: bogus` — but both were tried
under `-sm tensor` and both still logged the butterfly fallback.

**This is a ceiling, not a setting.** Lifting it means building `llamacpp-rocm`
ourselves and leaving lemonade's prebuilt binaries. Every tensor-split number in
this repo is therefore a floor.

**What lifting it would cost, in image terms.** The image ships no ROCm and no
llama.cpp today — lemonade downloads a 2.3 GB prebuilt `rocm-nightly` bundle at
runtime, and the `nightly` pin is what makes gfx1201 work at all. Building our
own means leaving that, in one of two shapes:

- **Ship our own bundle**: +2.3 GB for the bundle plus ~0.4 GB for RCCL
  (`librccl.so.1` measures 350–407 MB inside the vLLM image; it carries per-arch
  kernels). Call it +2.7 GB, and we take over tracking llama.cpp releases,
  losing lemonade's auto-update.
- **Build in CI**, publish the bundle as a release artifact, point lemonade at
  it. No image growth, but new infrastructure, a version pin to maintain, and it
  is unverified whether lemonade can be told to use a custom binary path at all.

Either way the build side needs a HIP/ROCm SDK container for gfx1201 plus RCCL
headers — build-time cost, not image content.

**And the payoff is unquantified, so do not lead with it.** The ceiling can be
bounded but not predicted: the no-MTP arms realise 1.39x of a theoretical 2x
(30.42 → 42.14), so a perfect reduction would be ~60 tok/s there, up to ~1.4x
more. Nobody has measured how much of that gap RCCL actually closes. Find a
cheaper way to measure the gap before spending an image on it.

`GGML_CUDA_P2P=1` does not help — peer access is real but runs at host-copy
speed ([runs/2026-08-30-p2p-bandwidth](../runs/2026-08-30-p2p-bandwidth.md)).

## KV quantisation composes with it

`-sm tensor -fa on -ctk q8_0 -ctv q8_0` loads, serves and gives identical
output, contradicting upstream's doc ("Support for quantized KV cache is not
implemented and trying to use it will result in an error"). At ctx 65536 it
saves 477 MiB across the pair (6352 → 5875 MiB).

The saving is small for *this* model because a GDN hybrid keeps only 16-of-64
full-attention layers; the rest is constant-size SSM state that KV-quant does
not touch.
