---
date: 2026-09-03
subject: rule out the ROCm#6347 spawn-lottery (~33 vs ~26 tok/s band) on this box
harness: /usr/share/kinoite/vllm/bench.py (baked into the image)
box: kinoite-north
---

# ROCm#6347 spawn lottery — ruled out

## What was measured

[ROCm#6347](https://github.com/ROCm/ROCm/issues/6347) reports gfx1201 decode
randomly locking to ~33 **or** ~26 tok/s at process spawn, unrecoverable without
restart. Six fresh vLLM starts with speculation off (`VLLM_SPECULATIVE=`), each
followed by `bench.py` at max_tokens=512.

## Numbers

Qwen/Qwen3.8-27B-FP8, TP=2, batch 1, non-speculative:

    spawn    rust    python  prose   MEAN
    1        24.53   24.56   24.51   24.53
    2        24.55   24.50   24.47   24.51
    3        24.56   24.52   24.49   24.53
    4        24.53   24.50   24.47   24.50
    5        24.54   24.50   24.49   24.51
    6        24.58   24.52   24.48   24.53

Range: 24.50–24.53 tok/s. **One band, not two.** The twelve prior service
starts (2026-08-19 through 2026-08-31) also never exceeded 24.3, so this is not
a new result — just the formal closure.

## Conclusion

ROCm#6347 does not reproduce on this box. The root cause may be the RCCL version
(2.29.7) or the kyuz0 image's patches, but the fact remains: 18 starts across
two sessions, all one band. The issue is ruled out and should not be re-chased.