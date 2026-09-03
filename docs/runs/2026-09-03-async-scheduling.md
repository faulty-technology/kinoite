---
date: 2026-09-03
subject: test --no-async-scheduling cost at k=4
harness: /usr/share/kinoite/vllm/bench.py (baked into the image)
box: kinoite-north
---

# Async scheduling — costs nothing at k=4

## Background

`--no-async-scheduling` was required whenever `disable_padded_drafter_batch` was
set. The drafter-batch flag was removed on 2026-08-24
([decisions/2026-08-24-drop-padded-drafter-batch](../decisions/2026-08-24-drop-padded-drafter-batch.md)),
but `--no-async-scheduling` stayed — the decision doc noted it cost 3.2% in the
08-22 sweep and speculated the cost would persist independently. That
measurement was contaminated: the arm labelled "`--no-async-scheduling` alone"
had `disable_padded_drafter_batch=false` while the control had it `true`, so the
3.2% was the drafter-batch flag's cost, not async scheduling's.

## What was measured

A/B at k=4 with and without `--no-async-scheduling`, Qwen/Qwen3.8-27B-FP8, TP=2,
batch 1, max_tokens=512. Two runs per arm, fresh load each time.

## Numbers

    arm                         run 1   run 2
    async scheduling            54.28   54.19
    --no-async-scheduling       54.26   54.25

    difference                  +0.02   -0.06

Acceptance length was ~3.20 (async) vs ~3.27 (no-async), consistent with the
normal run-to-run variance in this harness.

## Conclusion

`--no-async-scheduling` costs nothing at k=4. The flag is vestigial — it was
only required for `disable_padded_drafter_batch`, which is gone. It can be
removed from the launcher for cleanliness; throughput is the same either way.