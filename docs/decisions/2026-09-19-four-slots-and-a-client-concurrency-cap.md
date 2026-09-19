---
date: 2026-09-19
subject: Q8XL gets four slots, paired with a client-side cap of one simultaneous subagent; the two are one decision
---

# Four slots on Q8XL, and one subagent at a time on the client

## Decision

`--parallel 4 --kv-unified` on `user.Qwen3.8-27B-Q8XL`, `ctx_size` 262144, f16
KV. Paired with `MAX_CONCURRENCY = 1` in the laptop's
`~/.pi/agent/extensions/subagent/index.ts`, and advisor-M left enabled.

This supersedes [decisions/2026-09-18-three-slots-on-q8xl](2026-09-18-three-slots-on-q8xl.md).
Its reasoning — that a slot is sized by live conversations rather than
simultaneous ones — still stands and is what this builds on. Its count does not.

The server number is only correct for this client configuration. Raising the
client's concurrency cap without raising the slot count puts the thrash back.

## Why

**The client cap is what fixed the eviction, not the slot count.** Slots went
4 → 2 → 3 across 2026-09-18/19 and the miss rate barely moved. Capping
simultaneous subagents moved it an order of magnitude:

| | subagents ≤ 2 | subagents ≤ 1 |
|---|---|---|
| evicted conversations reprocessed | 9 | 3 |
| cost of those reprocesses | 345.3 s | 37.7 s |
| peak concurrent slots | 3 | 2 |
| decode median / p10 | 36.6 / 7.6 tok/s | 56.2 / 29.7 tok/s |
| time in prefill | 32% | 16% |

Both windows on 3 slots, 20 minutes each, same workload shape.

**Most "cache misses" were never a problem.** A slot selected by LRU is only
expensive when the conversation it evicted comes back and reprocesses. A brand
new subagent also selects by LRU and has nothing to restore, so its prefill is
work that would be paid anyway. Splitting the two changed the picture
completely: of 103 selections in one window, 80 hit cache, 14 were new
conversations, and only 9 were genuine evictions. Raw miss rate said 22%; the
rate that costs anything was 8.7%. Every slot-count decision before this one was
made against the inflated number.

**Three slots has no headroom.** Three live conversations — core agent, one
subagent, advisor-M's turn-end reviewer — exactly fill three slots. A new
subagent starting while the previous one's context is still resident makes four,
and something is evicted at every handover. LRU picks by recency, and a core
agent blocked on a serial subagent run is not touching its slot, so it is
routinely the least recently used thing in the pool despite being the one
conversation that must survive. The fourth slot absorbs that handover.

**Slots stopped being a contention risk once the client was capped.** The
earlier argument against more slots was prefill/decode collision: a large prefill
dominates the batch and starves whatever is generating beside it, which was
measured at 1.5 tok/s against a 28K prefill. That risk scales with simultaneous
*requests*, not with slots. With the client capped at one subagent, at most two
requests execute at once whatever `--parallel` says — peak concurrency measured 2
in every window since the cap. Extra slots now buy retention and nothing else.
Their VRAM cost is 21,443 / 21,615 / 22,359 MiB per card for 1 / 2 / 4 slots at
ctx 131072, against a pool sitting at 35% occupancy.

**advisor-M is affordable again, and was not before.** Its turn-end reviewer is a
throwaway `AgentSession` that takes a slot, never matches a cached prefix, and
discards its own cache immediately. On 2 slots with 2 live conversations that was
continuous eviction. On 4 slots with the client capped it costs nothing
measurable: 2 evictions and 25.6 s against 3 and 37.7 s with it disabled, and
peak concurrency stayed at 2 — it fires at turn end, when the main agent has just
finished and no subagent is running, so it lands in genuinely idle time.

## Rejected

**q8_0 KV cache to buy a larger pool.** Measured at 12% of decode at depth and
2.9 GiB per card,
[runs/2026-09-18-kv-quant-and-slot-count](../runs/2026-09-18-kv-quant-and-slot-count.md).
The eviction it would have paid for turned out to be caused by a per-agent
context budget advertising the whole shared pool, and by uncapped client
concurrency. Both were free to fix.

**Chasing the fan-out with slots.** `MAX_PARALLEL_TASKS` is 8, so a slot per
possible subagent is 9, and nine conversations at the observed 30-70K would need
270-630K cells against a 262,144 pool. Bounding the client is the only version of
this that terminates.

**Capping `MAX_PARALLEL_TASKS` instead of `MAX_CONCURRENCY`.** The first is the
batch size a caller may submit, the second is how many run at once. Only the
second holds slots. Batches larger than the cap still run, in waves.

## Unverified

Nothing here was measured above ~32K of conversation depth. The failure this
started from — a ~52K context evicted and re-read three times, and before that
100K+ reprocesses costing 240 s — has not recurred since the client was capped,
but neither has it been provoked. Four slots at 170K-per-conversation depth is
the case the 2026-09-18 run rejected, and the only thing standing between this
box and that case is the 128K per-agent budget set on the client.
