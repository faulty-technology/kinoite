# Choosing a quant

The seeded recipes are Q6_K with one deliberate IQ4_XS exception. The reasoning
is one measurement: **the weight-size axis is flat above ~25 GB**
([runs/2026-08-30-quant-sweep](../runs/2026-08-30-quant-sweep.md)).

## Q6 and Q8 decode at the same speed, only IQ4 is faster

25.3 GB and 31.5 GB of weights decode at the same rate to within noise, while
14.0 GB is 26% faster. Do not model this box's decode as proportional to weight
bytes.

The ms/pass decomposition says why. Slope — the context/KV term — is constant
across all three quants, since KV is f16 regardless. The *intercept*, the weight
term, is also flat between Q6 and Q8 and only drops at IQ4: a 2.21x change in
weight bytes moves it 21%, and the 1.24x from Q6 → Q8 moves it 0%. The large
fixed per-pass cost — butterfly reduction, CPU draft sampler, launch overhead —
dominates.

## The practical rule

**Quantising down from Q8 buys nothing until you go well below Q6.** If Q6 is
chosen for quality, Q8 is nearly free. If speed is the goal, only a jump to
~IQ4 pays.

That is why the seeds keep a Q6_K quality floor as the default and offer IQ4_XS
as an explicit, separately-named choice rather than a replacement.

## What has never been measured

**Quality.** Bits-per-weight is not an output-quality metric, and every
throughput table in this repo is silent on it. No A/B between FP8, Q8_K_XL and
IQ4_XS has been run on this box.
