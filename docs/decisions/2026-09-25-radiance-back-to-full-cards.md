---
date: 2026-09-25
subject: radiance goes back to upstream's full-card memory settings on the dfdfa38 pin; the client back to a 262K window and four subagents
---

# radiance back to the full cards

## Decision

`radiance.container` serves with `--gpu-memory-utilization 0.98
--kv-cache-memory 18563072000 --max-model-len 262144` again, upstream's settings
for this hardware. The `dfdfa38` pin from earlier today stays.

The client in the laptop's `~/.pi/agent` goes back with it: the radiance
`contextWindow` returns to 262144, and subagent `MAX_CONCURRENCY` to 4, the value
it ran at before today.

This supersedes
[decisions/2026-09-25-radiance-at-057-and-131k](2026-09-25-radiance-at-057-and-131k.md).
Its pin bump stands. Its memory ceiling, client window and subagent cap do not.

## Why

**The pool it called idle was the prefix cache.** In real use at 0.57 the prefix
cache hit rate fell from 95.6% to 41.9%. Computed prefill per generated token
rose from 7.9 to 47, and requests queued in 133 of 400 ten-second windows
against 2 of 980
([runs/2026-09-25-radiance-057-real-use-prefix-cache](../runs/2026-09-25-radiance-057-real-use-prefix-cache.md)).
A session's live conversations did not fit in 165,906 tokens. Each turn evicted
the others' history, and they recomputed it.

The superseded decision rested on a concurrency run that seeded every prompt
fresh, so it could not measure retention between turns. The same run record
explains why.

**The headroom had no user.** No second model was chosen, and the user will find
room for one another way. So the ~13.8 GiB freed per card bought nothing, and the
cost above is paid on every session.

## Rejected

**A middle ceiling, around 0.75.** Estimated at roughly 400K tokens with ~8 GiB
free per card, never measured. Without a second model to fit, it trades cache
for headroom nobody uses. It is worth measuring when a second model exists.

**Keeping 0.57 and one subagent at a time.** Two deep conversations still about
fill 165,906 tokens, so the core agent's history is evicted during every
subagent run.

## Unverified

The session that measured 0.57 ran with two subagents. How many ran in the 0.98
comparison window is not recoverable. That run record lays out why the pool
remains the likely cause regardless. `MAX_CONCURRENCY = 4` is restored as the
value in use before today, not re-derived. Its only supporting measurement is
that concurrency at depth costs no throughput on this pool
([runs/2026-09-20-radiance-concurrency-at-depth](../runs/2026-09-20-radiance-concurrency-at-depth.md)).
