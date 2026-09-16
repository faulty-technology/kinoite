---
date: 2026-09-15
subject: the per-card power cap is 250 W, and the bench that was meant to justify a cap number is dropped
---

# The 250 W cap is a choice, and the cap-cost bench is dropped

## Decision

`POWER_CAP_W` defaults to 250 in `tuning.sh`, up from 235, in the shipped
default and in `/usr/share/kinoite/gpu-tune.conf.example`. The open item asking
what the cap costs is closed without running the bench it asked for (removed in
`1ab0b91`).

## Why

The cooling A/B in
[runs/2026-08-25-vllm-context-and-clocks](../runs/2026-08-25-vllm-context-and-clocks.md)
already bounds the answer. At 235 W with stock fan behaviour the cap bound hard
— socket power pinned at 234/235 W, `sclk` ~2360 MHz. An aggressive `FAN_CURVE`
took hotspot from 88-93°C to 70-78°C, draw to 184-203 W and `sclk` to
~3370 MHz, +43% at the DPM ceiling. `ms/pass` at matched context moved
121.5 → 122.0: 0.4% *slower*, inside noise.

Two things follow. A cap that binds hard enough to cost 43% of GFX clock costs
nothing measurable on decode, because decode here is memory-bandwidth bound with
`mclk` at top DPM 1258 MHz throughout. And once the cards are cooled the
workload draws 184-203 W, so neither 235 nor 250 binds at all. A 15 W move on a
cap with ~47 W of slack cannot show up in a decode number — which is why the
measurement was dropped rather than run.

250 also stays under the 300 W `power1_cap_max` that applies without
`amdgpu.ppfeaturemask` ([reference/gpu-sysfs.md]), so the cap lands whether or
not the karg survives a rebase. A number above 300 would silently clamp on a box
that lost it.

Alternatives rejected:

- **Stay at 235.** Nothing measured says it is better, and it is the value from
  before the cooling fix — the number chosen when it was the one that bound.
- **Ship no cap.** `power1_cap` is the only knob here that survives an idle
  cycle, so it is the sole durable guard if cooling regresses. A documented
  number beats a firmware default nobody chose.
- **Run 235 against 250 first.** It would spend a bench on a question whose
  ceiling the 08-25 A/B already puts at 0.4% under a 43% clock swing.

## What this does not settle

**Why 250 rather than 245 or 260 is not recorded.** It is headroom, not a
measurement, and no number here distinguishes the neighbours.

**Nothing above is a graphics load.** Every figure is LLM decode. A game is the
workload that could plausibly hold an R9700 at a 250 W cap, and no run in this
repo has watched `power1_average` under Proton. If the cards do sit at the cap
while gaming, this decision does not cover it.

**Acoustics are untouched.** 30% is a hard firmware fan floor, so no cap value
makes an idle or lightly loaded card quieter.

## Revert

`POWER_CAP_W=235` in `/etc/kinoite/gpu-tune.conf`, or empty to leave the cards
at their firmware default. `sudo /usr/libexec/kinoite-gpu-tune status` shows
what is applied.
