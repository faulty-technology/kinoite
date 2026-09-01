---
date: 2026-08-25
subject: vLLM decode cost versus context depth, and a controlled A/B on GPU clocks and thermals
harness: in-situ fit against a live agentic workload, reading metrics.py:116
box: kinoite-north
---

# Context cost, and why clocks are not the lever

## What was measured

Fitted against a live agentic workload — single stream throughout, one request
growing its own context — reading `Drafted throughput`/k out of the
`metrics.py:116` log line to get the target-model forward pass directly. That is
the quantity deterministic in context depth; tok/s carries acceptance-length
noise.

Separately, an A/B on cooling at an unchanged 235 W cap, on a live workload.

## Numbers

    ms/forward_pass = 1.186 * (context in K tokens) + 47.2

55 points fitted over 45–58K, then validated against 41 further points at 62–70K
collected after an unrelated intervention: mean residual -0.09 ms (-0.1%), worst
|residual| 1.6 ms. Convert with `tok/s = 1000 * acceptance_length / ms_per_pass`;
acceptance ran 2.5–2.8 on real prose and code.

    ctx     ms/pass   tok/s @ acc 2.8
      20K      71          39
      40K      95          30
      70K     130          22
     128K     199          14

Cooling A/B — applying an aggressive `FAN_CURVE` at an unchanged 235 W cap:

    hotspot      88-93C   ->  70-78C
    socket power 234/235W ->  184-203W   (cap stops binding entirely)
    sclk         ~2360MHz ->  ~3370MHz   (+43%, at the DPM ceiling)
    ms/pass      121.5    ->  122.0      (matched context)

The non-speculative baseline is dead flat in context: 24.35 at a 15-token prompt
down to 22.99 at 32K, a 4% decline over a 2000x context increase. Confirmed
independently by vLLM's `Avg generation throughput` logger across twelve service
starts, which never exceeded 24.3.

## What it means

**At 70K the context term is 83 of the 130 ms — 64% of the forward pass.** Past
~40K the KV, not the weights, is what you are paying for.

**Context management beats kernel tuning here.** Holding a working context at 20K
instead of 70K is ~1.8x decode for free — more than the drafter-batch flag
(+19.1%) and the k=1→3 move (+35%) put together
([runs/2026-08-22-vllm-speculation-sweep](2026-08-22-vllm-speculation-sweep.md)),
and it needs no image, no flag and no measurement.

**Do not extrapolate the fit below its range.** The 47.2 ms intercept implies
~64 tok/s at zero context against a measured 54.22, so it is optimistic by ~15%
once context stops dominating. Quote it for 40–130K only.

The baseline being flat is a property of the architecture: 48 of the 64 layers
are linear-attention with constant-size state, so per-token cost is fixed. That
result is about the **non**-speculative arm and still holds there. With MTP on,
decode falls off hard with depth — 67.6 short, 47.6 at ~9.5K, 29.1 at ~38K. Both
arms decay by the same proportion, so k=3 stays ~40% ahead everywhere.

**The clock deficit is leakage, not performance.** At 90 °C the cards leak enough
extra current to pin themselves against the cap, which clamps clocks; cooling
them drops leakage ~45 W/card, which releases the cap, which lets clocks rise —
and none of it matters, because batch-1 decode is memory-bandwidth bound and
`mclk` sat at top DPM 1258 MHz throughout, before and after. GFX clock is not on
the critical path at batch 1, and neither is the power cap. Do not raise it
hoping for tok/s, and do not let a THROTTLED flag or a 90 °C hotspot send you
back here.

Keep the fan curve anyway — ~18 °C and ~90 W across the pair for identical work
is a thermal and efficiency win. It is just not a throughput knob.

**The trap that made this look like a regression**, because it will catch the
next person: an in-flight request at 58K context was compared against the
fresh-load short-prompt sweep figure. That manufactured a ~17 ms/pass phantom
deficit out of nothing but context depth. Fit the context model and compare
against it, or compare two runs at the same depth.
