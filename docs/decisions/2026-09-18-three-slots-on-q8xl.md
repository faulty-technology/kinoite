---
date: 2026-09-18
subject: Q8XL gets three slots, because slot count follows live conversations rather than concurrent requests
---

# Three slots on the Q8XL daily driver

## Decision

`--parallel 3 --kv-unified` on `user.Qwen3.8-27B-Q8XL`, up from the 2 baked
earlier the same day and down from the 4 before that. `ctx_size` stays 262144
and the KV cache stays f16.

This supersedes the slot-count conclusion of
[runs/2026-09-18-kv-quant-and-slot-count](../runs/2026-09-18-kv-quant-and-slot-count.md).
Everything that run measured still holds; what it reasoned from does not.

## Why

That run cut 4 to 2 on the grounds that three or more streams are live under 2%
of busy wall time. That statistic is about **concurrent execution**, and slot
count is not sized by it.

A slot does two jobs. It runs a request, and it retains that conversation's
cache between requests. The second job is the binding one: a conversation that
loses its slot reprocesses from zero next time it is used, whether or not it was
ever running at the same moment as another. Interleaved conversations need a slot
each exactly as much as simultaneous ones do, and this box's traffic interleaves
almost exclusively — 0% two-slot wall time was observed in a 15-minute window
during which both slots were held by distinct conversations.

The agent topology is one core agent fanning out to two worker streams: three
live conversations. At two slots the two workers claimed both slots in the same
second (two `selected slot by LRU` at 23:46:32, one per slot), evicting the core
agent's 104,609-token context, which then had to reprocess. The pool was 50%
full at the time, so the eviction bought nothing — there were cells free and no
slot to point at them.

Slots are cheap next to the pool: 21,443 / 21,615 / 22,359 MiB per card for 1, 2
and 4 slots at ctx 131072
([runs/2026-09-18-lemonade-parallel-slots](../runs/2026-09-18-lemonade-parallel-slots.md)).
So the only reason to withhold one is pool competition, and that only bites once
the cells are actually full. Four was genuinely too many at ~170K session depth,
where four caches oversubscribe 262144 and evict on nearly every switch. Two is
too few for a three-conversation fan-out at any depth.

Three is fitted to the current fan-out, not to a swept optimum. A wider fan-out
needs a wider setting, and the same reasoning gives the number: one slot per live
conversation, until the pool is the thing that runs out.

Two deep sessions remain unsolved at every slot count — 2 x ~170K exceeds a
262,144 pool on its own. Only a larger pool moves that, which needs the q8_0 KV
cache and the 12% of decode it costs.
