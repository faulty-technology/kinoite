---
date: 2026-08-23
subject: whether the undervolt, power cap and fan curve survive a runtime-suspend cycle
harness: hand-written sysfs values, lactd stopped
box: kinoite-north
---

# What survives an idle cycle

## What was measured

The `amdgpu.ppfeaturemask` karg live, `lactd` stopped, and both values written
by hand straight to sysfs, so LACT is not in the picture at all.

Apply `power1_cap=210000000` and `vo -25` + `c` to an awake card, let it
runtime-suspend (~9–12 s), wake it, re-read. Two consecutive cycles.

## Numbers

| setting | after one idle cycle |
|---|---|
| `power1_cap` 210 W | **still 210 W** |
| `OD_VDDGFX_OFFSET` -25 mV | back to `0mV` |
| committed 5-point fan curve | all five points read `0C 0%` |

Also from this session:

- `power1_cap_max` rises 300 W → 330 W with the karg, so 210 W is a cap against
  330, not 300.
- OD writes need no `performance_level=manual`. `vo -25` + `c` commits at
  `auto`, rc=0, and `vo 0` + `c` cleanly reverts.
- `systemctl stop lactd` → `power1_cap` goes straight back to 300000000 on both
  cards.

## What it means

`power1_cap` is durable across a D3→D0 transition. Everything in the OverDrive
table is not — amdgpu restores the cap and drops the OD table.

This is not a suspend/resume edge case. It fires every time the cards go idle
for ten seconds, many times a day, so a "set it and forget it" undervolt or fan
curve is impossible here.

LACT reverting the cap on stop rules out any "start LACT, let it apply, stop it"
design. LACT can only own a setting for as long as LACT is resident.
