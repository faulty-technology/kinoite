---
date: 2026-08-22
subject: vLLM MTP speculation — drafter-batch flag, k sweep, and behaviour at batch >1
harness: /usr/share/kinoite/vllm/ksweep.py and bench.py (baked into the image)
box: kinoite-north
---

# vLLM speculation sweep

## What was measured

Qwen/Qwen3.8-27B-FP8, TP=2, batch 1 unless stated. Fresh load per arm,
correctness clean. Control reproduced 54.20 / 54.21 against the 54.22 recorded
two days earlier.

## Numbers

The drafter-batch flag, five arms:

    arm                              MEAN    vs ctl   accept   rust    python  prose
    control (k=3)                    54.21     --     3.020    55.42   58.29   48.90
    --no-async-scheduling alone      52.48    -3.2%   3.000     --      --      --
    + disable_padded_drafter_batch   64.54   +19.1%   3.006    64.37   67.10   62.16   <- adopted 08-22
    + prefix caching as well         64.11   +18.3%   2.975    63.52   69.14   59.67

The scheduling arm was run alone, so the headline is quoted net of its -3.2%.

K sweep under the current default, one run per k:

    k       rust  python   prose    MEAN  accept  per_dft
    1      48.67   49.18   46.17   48.00   1.870    0.870
    2      59.39   61.54   55.22   58.72   2.516    0.758
    3      64.43   67.14   62.15   64.57   3.006    0.669   <- default at the time
    4      65.95   72.03   59.40   65.79   3.277    0.569
    5      59.32   72.85   55.45   62.54   3.397    0.479
    6      65.44   67.45   53.10   61.99   3.587    0.431

At batch >1 (measured 2026-08-20; 4 concurrent requests x 384 tokens, released
from a barrier, `ignore_eos`, median of 3):

    metric                        k=1      k=3      gain
    single stream                 40.76    67.58    +66%
    aggregate, 4 concurrent      139.02   187.11    +35%
    per-stream while batched     33.2-37.6 48.0-59.7
    ~9.5k-token prompt            33.14    47.55    +43%
    ~38k-token prompt             20.83    29.08    +40%

Correctness gate (counting 1–40, 17*23, exact-word echo) passes at k=3.

Historical defaults, same model and topology:

    MTP k=4                                               55.9 mean         (2026-08-26)
    k=3 + drafter-batch                                   62.2 - 67.1 tok/s (2026-08-22)
    MTP k=3                                               48.9 - 58.3       (2026-08-20/22)
    MTP k=1                                               36.8 - 39.2       (2026-08-20)
    no MTP                                                24.3              (2026-08-19)

## What it means

The drafter-batch flag adopted here was removed two days later — it crashes the
engine under concurrency. See
[decisions/2026-08-24-drop-padded-drafter-batch](../decisions/2026-08-24-drop-padded-drafter-batch.md).

Acceptance is flat across the drafter-batch arms, so the +19.1% is padding
overhead removed, not better speculation.

**k=4 wins MEAN by 1.9% and is still the wrong default.** `per_dft` falls
0.669 → 0.569, meaning 43% of drafts are wasted — costlier as batch rises, and
this box runs `--max-num-seqs 4`. It regresses the worst workload (prose 62.15 →
59.40). And 1.9% is inside this harness's noise: k=5 and k=6 are non-monotonic.
One run per k shows the shape, not a 2% difference.

k=3 costs nothing at batch >1, which was the thing worth checking — speculation
wastes compute when it guesses wrong, and that waste is normally what makes big
k a bad idea on a server.

**Do not quote the `ignore_eos` single-stream figures** (67.58 vs the sweep's
54.22). Forcing the model past its natural stop into low-entropy filler is
something MTP predicts unusually well. Fine for an A/B where both arms do it,
wrong as a headline. The honest single-stream figure is the sweep table's.
