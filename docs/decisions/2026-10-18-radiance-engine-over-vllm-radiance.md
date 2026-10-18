---
date: 2026-10-18
subject: radiance.container switches from the patched-vLLM stack to StillDeadcode's radiance engine 1.8.1, same weights, on trial in real use
---

# radiance engine over vllm-radiance

## Decision

`radiance.container` serves Qwen3.8-27B MXFP4 with StillDeadcode's standalone
radiance engine, image 1.8.1 (`sha256:d590e300…`), and the `.rad` container
pinned by Hugging Face revision and sha256. It replaces vllm-radiance at pin
`dfdfa38`.

These stay the same:
- the unit name, port 8005, loopback binding and model id `Qwen3.8`;
- 262,144 tokens of context, 8 sequences and fp8 KV;
- the request defaults: sampling 0.7 / 0.95 / 20, and reasoning effort `medium`.

`--checkpoint-slots` is left at `auto`. `--prefill-span` is off.

This is a trial. If real use feels worse, the commit is reverted. The old stack's
checkpoints and image stay on the box, so a revert downloads nothing.

## Why

The user chose it after
[runs/2026-10-18-radiance-engine-181](../runs/2026-10-18-radiance-engine-181.md).

- **The blocker from 10-08 is fixed.** The default checkpoint store no longer
  drops DFlash2 drafting on follow-up turns. Turns 2–4 decode at 104–249 tok/s
  with stock settings.
- **The bench's headline understated the engine.** Cold prefill still favours the
  old stack by 17–24%, and it is what the 10-08 decision turned on. Real use on
  this box, though, is 95.6% prefix-cache hits and 7.9 computed prompt tokens per
  generated token
  ([runs/2026-09-25-radiance-057-real-use-prefix-cache](../runs/2026-09-25-radiance-057-real-use-prefix-cache.md)).
  Weighted that way, the engine's 4–23% decode lead roughly offsets its prefill
  deficit. That is an estimate, not a measurement.
- **Quality is equal.** The weights are identical, and GSM8K at 150K came out 478
  against 480 of 500.
- **The engine also brings:**
  - a 34% larger KV pool and a host tier for the prefix cache;
  - a 20 s start, with nothing patched or compiled at start;
  - more model families from the same engine;
  - an upstream that releases every few days, where the vLLM fork's last commit
    was 2026-09-26.

## Rejected

- **Keeping vllm-radiance.** It still wins every cold-prompt measurement. But its
  fork has gone quiet, every start patches and compiles vLLM, and the
  real-use-weighted gap is too small to justify those costs.
- **hipfire.** It serves the dense 27B on one card only, with its own quant
  formats. Its prefix cache is experimental and off by default, and its batching
  covers only thinking-off, single-turn requests. That is the wrong shape for an
  agent client at depth.
- **`--prefill-span 2`.** Prefill was flat, and decode after shallow prefix hits
  fell to 63–69 tok/s.

## Supersedes

The 10-08 run left adoption open, and its finding that the engine "gives up a
quarter of prefill" still stands. This is the decision it did not make.
[decisions/2026-09-25-radiance-back-to-full-cards](2026-09-25-radiance-back-to-full-cards.md)
still holds: its argument, that the big pool is the prefix cache, carries over
to this engine's larger pool.
