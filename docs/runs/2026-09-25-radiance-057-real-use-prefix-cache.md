---
date: 2026-09-25
subject: "radiance at 0.57 and 131K in real use against 0.98 and 262K: the pool was the prefix cache"
harness: none; read-only. The radiance unit's journal on north (vLLM's 10-second `Engine 000` log lines) and :8005/metrics, over two windows of the user's own pi sessions; no synthetic load, no restart
box: kinoite-north
---

# radiance at 0.57 in real use: the pool was the prefix cache

## What was measured

[decisions/2026-09-25-radiance-at-057-and-131k](../decisions/2026-09-25-radiance-at-057-and-131k.md)
shrank radiance's pool from 943,581 tokens to 165,906 on the argument that the big pool
sat idle. The user reported the first real session at the new settings as sluggish, so
the same journal figures were compared across two windows of real use. Nothing was
restarted or loaded for this.

- **A: 0.98, pinned KV, 262144**, pin `9735329`. 2026-09-21 10:20 to 2026-09-22 00:12,
  980 ten-second windows. That span includes suspends and idle time.
- **B: 0.57, profiled KV, 131072**, pin `dfdfa38`, client window 131072 and 2
  simultaneous subagents. 2026-09-25 18:32 to 21:39, 400 windows, one working session.

The windows differ in length and workload, so only rates within each window are
compared, not totals. vLLM's logged prompt throughput counts prompt tokens actually
computed, not those served from the prefix cache. B's journal sum, 10.64M, matches its
own counters: 18.37M prompt tokens minus 7.73M prefix-cache hits.

## Numbers

| | A: 0.98 / 262K | B: 0.57 / 131K |
|---|---|---|
| prefix cache hit rate, last logged | **95.6%** | **41.9%** |
| prompt tokens computed | 8.05M | 10.64M |
| tokens generated | 1.014M | 0.224M |
| computed prompt per generated token | **7.9** | **47** |
| windows with a request waiting | 2 of 980 | 133 of 400 |
| windows with KV above 90% | 0 of 980 | 19 of 400 |
| most requests running + waiting at once | 6 | 4 |
| preemptions | not recorded (counter resets per start) | 73 |

B's log over the last 40 minutes read by the user's complaint alternates two states.
In one, prompt throughput is 3,768–9,239 tok/s with generation at 12–37 tok/s and one
or two requests waiting. In the other, prompt throughput is 0 and generation runs at
165–194 tok/s. At its low point generation was 1.8 tok/s with two requests running and
two waiting.

## What it means

**The pool's real job is the prefix cache, and at 0.57 it cannot hold a session's live
conversations.** A pi session keeps several conversations alive at once: the core
agent plus up to two subagents, each with tens of thousands of tokens of history. At
0.98 all of their histories stay resident between turns, so 95.6% of every prompt is
a cache hit. At 165,906 tokens, whichever conversation runs evicts the others'
history. Each one then recomputes most of its context on its next turn. Computed
prefill per generated token rose about sixfold, and at ~4,000 tok/s that prefill is
what the user felt.

**The decision's evidence could not see this.**
[runs/2026-09-20-radiance-concurrency-at-depth](2026-09-20-radiance-concurrency-at-depth.md)
seeded every prompt fresh on purpose, so no request could hit the cache. It measured
throughput under no reuse, which is correct for what it asked and says nothing about
retention between turns. The
[09-15 floor](2026-09-15-radiance-quadlet-floor.md) measured decode alone, which the
pool indeed does not affect.

**Not separated here:** how much of B's slowdown is the pool, and how much is the
client going from however many subagents ran in A to two. That count is not
recoverable for window A. A's peak of 6 requests running or waiting against B's 4
suggests A was running at least as much concurrency, which points at the pool.
