---
date: 2026-10-18
subject: StillDeadcode's radiance engine 1.8.1 against the shipped vllm-radiance, same window
harness: ~/bench/radeng/ (off-repo, on the box), the 10-08 harness unchanged. radeng-bench.py, run-client.sh, gsm8k-deep.py. arm18.sh is arm.sh with the 1.8.1 digest; engine181.sh runs the engine arms; efftest.py checks reasoning-effort handling. Raw: bench-A181-prod.jsonl, bench-A181-turns.jsonl, bench-B181-tp2.jsonl, bench-B181span.jsonl, gsm8k-B181-tp2.jsonl, serve-v181-*.log
box: kinoite-north
---

# radiance engine 1.8.1 against the shipped vllm-radiance

## What was measured

This reruns [runs/2026-10-08-radiance-engine-v1-vs-vllm-radiance](2026-10-08-radiance-engine-v1-vs-vllm-radiance.md)
against engine 1.8.1, released today, five releases after 1.3.0. It uses the same
harness, the same `.rad` (sha256 `a4908940…`, unchanged on Hugging Face since
2026-10-07) and the same 250 W cap. All arms ran 17:03–18:09 EDT.

- **A, shipped.** `radiance.container` as built: vllm-radiance pin `dfdfa38`,
  0.98 with the KV pin, 262,144 context, 8 seqs, fp8 KV, on `:8005`.
  - Control, depth and concurrency ran first, at 17:03.
  - Its turns section was cut off when the service was stopped for the engine
    arms. It was rerun alone at 18:08 after a fresh start.
- **B181, engine.** Image `docker.io/stilldeadcode/radiance@sha256:d590e300…`
  (1.8.1) with `--tp 2 --max-model-len 262144 --max-num-seqs 8 --kv-cache-dtype
  fp8 --prefix-cache-mib 8192`. `--checkpoint-slots` was left at its new default,
  `auto`. The full client ran, including GSM8K.
- **B181span.** B181 plus `--max-num-batched-tokens 4096 --prefill-span 2`, which
  is 1.7.0's opt-in prefill option. Only depth and turns ran.

## Numbers

**Start to serving:**
- B181: 21 s.
- B181span: 20 s.

**Checkpoint slots:** the startup log reads `auto: 50 linear-state snapshot(s) of
153.38 MiB in pinned host memory (7.49 GiB) … 80 wanted, held to an eighth of
host memory`. `radiance:prefix_cache_ckpt_refused_total` was 0 over B181.

**Prefill, cold, tok/s:**

| prompt tokens | A | B181 | B181span | 1.3.0 (10-08) |
|---|---|---|---|---|
| ~7.6K | 5,485 | 4,563 | 4,544 | 4,551 |
| ~31K | 5,123 | 4,151 | 4,112 | 4,168 |
| ~64K | 4,634 | 3,705 | 3,684 | 3,728 |
| ~128K | 3,865 | 3,006 | 2,994 | 3,018 |
| ~201K | 3,243 | 2,487 | 2,487 | 2,493 |
| ~254K | 2,902 | 2,211 | 2,202 | 2,183 |

- A is 17–24% faster than B181 at every depth, and the gap widens with depth.
- B181 is within 1.3% of 1.3.0 at every point.
- The 254K cold prefill took 114.95 s by the client's clock and 114.92 s by the
  engine's own log.

**Decode after a prefix hit, tok/s (512 tokens):**

| prompt tokens | A | B181 | B181span |
|---|---|---|---|
| ~7.6K | 187 | 208 | **69** |
| ~31K | 182 | 206 | **63** |
| ~64K | 169 | 183 | 183 |
| ~128K | 154 | 160 | 184 |
| ~201K | 124 | 152 | 148 |
| ~254K | 141 | 158 | 145 |

**Short-prompt decode, tok/s, rust / python / prose:**
- A: 163 / 228 / 154.
- B181: 175 / 257 / 152.

**Concurrency at 45K, wall seconds for N = 1 / 2 / 4:**
- A: 10.7 / 20.1 / 39.1.
- B181: 12.7 / 24.8 / 47.2.

**Turns at ~110K.** Two sessions, interleaved, 4 turns each. Turn 1 is a cold
prefill. B181's decode figures come from the engine's per-request log line; vLLM
logs none.

| | turn 1 TTFT | turns 2–4 TTFT | decode on turns 2–4 | section wall |
|---|---|---|---|---|
| A | 27.1–27.3 s | 1.0–1.6 s | not logged | 68.1 s |
| B181 | 34.7 s | 1.1–1.8 s | 104–249 tok/s | 82.4 s |
| B181span | 35.0 s | 1.4–2.0 s | 128–232 tok/s | — |

Replies on turns 2–4 were 31–169 tokens long, so the per-turn decode rates are
noisy.

**GSM8K at ~150K** (500 questions, 1024-token cap, thinking off):
- B181: 478/500 = 95.60%, 10 truncated, 2.9 s per question.
- Paired with 1.3.0's 479/500 from 10-08: 1 question right only on 1.3.0, 0 right
  only on 1.8.1. McNemar exact p = 1.000, agreement 99.8%.
- A's reference is 480/500
  ([runs/2026-09-20-radiance-vs-q8xl-quality-at-depth](2026-09-20-radiance-vs-q8xl-quality-at-depth.md)).

**Request handling.** Tested on B181 with the flags `radiance.container` now
ships: `--temp 0.7 --top-p 0.95 --top-k 20 --reasoning-effort medium
--reasoning-effort-map high=xhigh,max=xhigh,minimal=low`.
- `/server_info` reported those as the request defaults.
- The tool-call check passed, and an `Authorization: Bearer` header with no
  `--api-key` set was accepted.
- Reasoning returns in `reasoning_content`.
- Unset, `low`, `xhigh` and `high` all thought, with 47, 83, 164 and 154
  characters of reasoning. Top-level `reasoning_effort: "none"` and
  `enable_thinking: false` gave 0.
- `chat_template_kwargs.reasoning_effort: "none"` was refused with HTTP 400, as
  was the unknown level `ultracode`.

## What it means

**1.8.1 fixes the default that hurt follow-up turns on 10-08, and nothing about
prefill.**
- With `--checkpoint-slots auto`, turns 2–4 decode at 104–249 tok/s. Under
  1.3.0's 8-slot default they ran at 50–78.
- The repeated 201K hit decodes at 152 tok/s. On 1.3.0 it was 44–48.
- On this box `auto` takes 50 slots, below the 64 that 10-08 used to fix the
  turns. Nothing was refused in this workload.
- Cold prefill is where it was on 1.3.0, still 17–24% behind A.

**`--prefill-span 2` should stay off here.** Prefill was flat to 1% slower.
Decode after a shallow hit fell to 63–69 tok/s, because span steps skip their
inner checkpoints, as the engine's guide warns. At depth it made no consistent
difference.

**Decode favours the engine, and cold prefill favours A.** Every cold-prompt
section, which is depth, concurrency and turn 1, goes to A. Decode after a hit goes
to B181 at every depth, by 4–23%. Short-prompt decode goes to B181 on code by
7–13%, and is level on prose, at 152 against 154. The turns section shows how the two combine on
this harness: 68.1 s for A against 82.4 s for B181. Turn 1's cold prefill is 55
and 69 s of those totals.

The real-use mix on this box is 7.9 computed prompt tokens per generated token
([runs/2026-09-25-radiance-057-real-use-prefix-cache](2026-09-25-radiance-057-real-use-prefix-cache.md)).
Weighted by that mix, the two come out close. That is an estimate from these
rates, not a measurement. This harness cannot measure it, because every section
opens with a cold prompt.

**Quality is unchanged.** Same weights, and 99.8% agreement with 1.3.0.

**Not measured:**
- Repeats. Each point ran once, in one window.
- A real-use replay.
- Sampled decode with thinking on.
- Behaviour across a suspend.
- Prose, code or multi-turn tool-use quality.
- The new unit as a systemd service. Its flags ran in a podman arm, and its
  Quadlet output was checked with `quadlet -dryrun`.
