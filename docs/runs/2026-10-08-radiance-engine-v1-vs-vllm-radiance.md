---
date: 2026-10-08
subject: StillDeadcode's radiance engine 1.3.0 against the shipped vllm-radiance, same window
harness: ~/bench/radeng/ (off-repo, on the box). radeng-bench.py (OpenAI chat API only, salted filler, server usage counts, thinking off, temperature 0), run-client.sh (sanity, toolcheck-openai.py, thinking-on reply, radeng-bench, gsm8k-deep.py), arm.sh (podman launch of the engine on :8006). Raw: bench-*.jsonl, serve-*.log, stats-*.json, gsm8k-B-tp2.jsonl
box: kinoite-north
---

# radiance engine 1.3.0 against the shipped vllm-radiance

## What was measured

StillDeadcode released a standalone C++/HIP inference engine,
[codeberg.org/StillDeadcode/radiance](https://codeberg.org/StillDeadcode/radiance).
Its tags run from v1.0.0 on 2026-10-04 to v1.3.0 on 2026-10-08. It is not
the vllm-radiance stack `radiance.container` ships, and it shares only the
author and libr4d with it. It serves `StillDeadcode/qwen3.8-27b-mxfp4.rad`
(sha256 `a4908940…`), which holds AMD's Quark AWQ-MXFP4 trunk byte for byte,
the same weights the shipped stack serves, with a merged DFlash2 drafter
(MXFP4 linears, 2-bit rescored head). The question was whether it should
replace the shipped stack.

**Arms.** All three ran in one window, 19:41–21:45 EDT, under the shipped
250 W cap.

- **A, shipped.** `radiance.container` as built: vllm-radiance pin `dfdfa38`,
  0.98 with the KV pin, 262,144 context, 8 seqs, fp8 KV, on `:8005`. Warm
  compile cache, run after B.
- **B, engine, two cards.** Image `docker.io/stilldeadcode/radiance@sha256:641f2d8d…`
  (1.3.0) with `--tp 2 --max-model-len 262144 --max-num-seqs 8
  --kv-cache-dtype fp8 --prefix-cache-host-mib 16384`.
  - **B2:** `--checkpoint-policy keep-all`.
  - **B3:** `--checkpoint-slots 64 --prefix-cache-host-mib 8192`. B2 and B3
    were relaunched for the follow-up-turn finding below.
- **C, engine, one card.** B3's flags with `--tp 1`.

**Method.** Every prompt opens with a random salt, so cold prefills are never
cache hits.

- **Depth point:** one cold request with `max_tokens 1`. Prefill is prompt
  tokens divided by wall time. Then the same prompt again (a prefix hit) for
  512 tokens, giving hit TTFT and decode from first token to last. One rep per
  point.
- **Concurrency:** 1, 2 and 4 simultaneous fresh 45K prompts at 256 tokens.
- **Turns:** two ~110K sessions, interleaved, 4 turns each, with about 1K
  tokens appended per turn.
- **GSM8K:** 500 questions at a 149,753-token shared prefix, 1024-token cap,
  thinking off.
  - B was run here.
  - A is the 09-20 run of the same harness, the same prefix (`/tokenize` gave
    the same count) and the same questions, at the shipped stack's earlier
    pin ([runs/2026-09-20-radiance-vs-q8xl-quality-at-depth](2026-09-20-radiance-vs-q8xl-quality-at-depth.md)).

## Numbers

| | A shipped | B engine TP2 | C engine TP1 |
|---|---|---|---|
| KV pool, tokens | 943,581 | 1,268,272 (B3: same) | 332,048 |
| start to serving | ~2 min (warm cache) | ~1 min | ~1 min |
| sanity, tool call, thinking on | pass | pass | pass |

**Prefill, cold, tok/s:**

| prompt tokens | A | B | C |
|---|---|---|---|
| ~7.6K | 5,478 | 4,551 | 2,837 |
| ~31K | 5,111 | 4,168 | 2,549 |
| ~64K | 4,623 | 3,728 | 2,234 |
| ~128K | 3,860 | 3,018 | 1,751 |
| ~201K | 3,241 | 2,493 | 1,400 |
| ~254K | 2,902 | 2,183 | 1,219 |

A is 20–33% faster than B at every depth, and the gap widens with depth.

**Decode after a prefix hit, tok/s (512 tokens):**

| prompt tokens | A | B | C |
|---|---|---|---|
| ~7.6K | 181 | 199 | 131 |
| ~31K | 177 | 204 | 121 |
| ~64K | 181 | 203 | 102 |
| ~128K | 169 | 182, then 51 on a repeat (B3: 176) | 106 |
| ~201K | 147 | 48, 44, 48 | 88 |
| ~254K | 136 | 159 | 84 |

**Short-prompt decode, tok/s, rust / python / prose:**

| A | B | C |
|---|---|---|
| 163 / 228 / 154 | 174 / 255 / 153 | 108 / 152 / 90 |

**Concurrency at 45K, wall seconds for N = 1 / 2 / 4:**

| A | B | C |
|---|---|---|
| 10.8 / 20.2 / 39.1 | 12.6 / 24.9 / 47.3 | 21.3 / 41.5 / 77.8 |

Wall time scales linearly with N on both engines, as on A before
([runs/2026-09-20-radiance-concurrency-at-depth](2026-09-20-radiance-concurrency-at-depth.md)).

**Turns at ~110K.** Turn 1 is a cold prefill in every arm. Turns 2–4 are
cache hits.

| | turn 1 TTFT | turns 2–4 TTFT | decode on turns 2–4 |
|---|---|---|---|
| A | 27.5 s | 1.0–1.6 s | not logged per request by vLLM |
| B (8 checkpoint slots, default) | 35.0 s | 0.6–0.9 s | **50–78 tok/s** |
| B2 (keep-all) | 34.7 s | 0.5–1.8 s | 46–68 for session A; 125–226 for session B |
| B3 (64 slots) | 34.7 s | 1.1–1.8 s | **127–283 tok/s** |
| C | 60.1 s | 1.0–3.0 s | — |

**GSM8K at ~150K:**

| | correct | truncated |
|---|---|---|
| A (09-20) | 480/500 = 96.00% | 9 |
| B | 479/500 = 95.80% | 10 |

- Paired: 4 questions A-only and 3 B-only, McNemar exact p = 1.000, agreement
  98.6%.
- B ran at 2.9 s per question with a prefix hit rate of 96.8%, 0 preemptions
  and draft acceptance 0.69 overall (per-position 0.90–0.91).

**Other observations on B:**

- **Watchdog line.** During the 4×45K concurrent prefill, the log printed
  `E device: a synchronisation has waited 5 s` naming `r4d_attn_prefill_kernel`.
  All four requests completed, and the server stayed healthy.
- **Pinned host memory.** The engine pins the token embedding (1.18 GiB per
  rank) in host memory. The prefix-cache host tier and the checkpoint slots
  (76.69 MiB per rank per slot) are pinned as well.

## What it means

**The engine gives up a quarter of prefill to the shipped stack, and prefill is
what this box's work waits on.** At every depth, A prefills 20–33% faster, and
the gap grows with depth. B's advantages are real but secondary:

- A pool 34% larger. Real use peaked at 56.8% of A's pool between 09-26 and
  09-30 (north's journal), so A's pool already covers it.
- About 10% faster decode at shallow-to-mid depth.
- A host prefix-cache tier.
- A one-minute start with nothing patched or compiled at start.

**Quality is equal.** The pair cannot tell the two apart at 500 questions,
which is expected: the weights are identical.

**The engine's default is wrong for agentic follow-ups at depth.** With the
default 8 linear-state checkpoint slots, a cache hit that reaches nearly to
the end of the prompt is kept whole. The DFlash2 drafter then has a hole in
its window and does not draft, so decode runs at 45–78 tok/s instead of about
200. That is exactly the shape of a follow-up turn: a long cached history plus
a short new message.

`--checkpoint-slots 64` restores the refill, giving 127–283 tok/s on follow-up
turns and 176 tok/s on the 128K repeat. The cost is about 4.8 GiB of pinned
host memory per rank and about 0.5–1 s more TTFT per turn. Any adoption needs
that flag.

**One card (C) is not a way to free the other card for a second model.** Its
332,048-token pool is below the observed peak demand of about 536K, and it
prefills at 58–60% of B's rate.

**Not measured:**

- Repeats. There was one rep per point and one window.
- A's decode on follow-up turns.
- B3's full depth series beyond 128K.
- The engine's disk tier.
- Behaviour across a north suspend.
- Prose, code or multi-turn tool-use quality.
