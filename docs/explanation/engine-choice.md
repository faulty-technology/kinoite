# Why llama.cpp is the decode path

Two engines are built for this box and only one can run at a time: lemonade
(llama.cpp) and vLLM + Open WebUI. lemonade Q8XL holds ~22 GB per card and vLLM
FP8 needs ~28 GB of 32 GB, so they cannot coexist — every comparison behind this
page is sequential for that reason.

## The verdict

**llama.cpp is the decode path, and that survives turning vLLM's prefix caching
on.** It was 2.01x ahead on end-to-end agentic throughput when vLLM shipped with
caching off, and is still 1.16x ahead now that it ships on
([runs/2026-08-31-agentic-decode](../runs/2026-08-31-agentic-decode.md)).

What changes is the *shape* of the win, and that is the part worth knowing. With
caching off vLLM lost on prefill *and* decode. With it on it wins prefill by
2.2x and loses decode by 1.41x — and decode is what dominates once a
conversation is warm. So the remaining gap is a genuine engine-speed gap, not a
missing-feature gap.

## Where each engine actually wins

| axis | winner | margin | measured in |
|---|---|---|---|
| decode, single stream, any depth | **llama.cpp `-sm tensor`** | 1.22x–2.61x | [2026-08-30-engine-decode-depth](../runs/2026-08-30-engine-decode-depth.md) |
| end-to-end agentic, current defaults | **llama.cpp** | 1.16x | [2026-08-31-agentic-decode](../runs/2026-08-31-agentic-decode.md) |
| end-to-end agentic, vLLM caching off | **llama.cpp** | 2.01x | [2026-08-31-agentic-decode](../runs/2026-08-31-agentic-decode.md) |
| warm-prefix TTFT | **vLLM + prefix caching** | 2.2x | [2026-08-31-agentic-decode](../runs/2026-08-31-agentic-decode.md) |
| cold prefill throughput | **vLLM** | ~2.6x (1,355 vs 513 t/s) | [2026-08-31-journal-real-use](../runs/2026-08-31-journal-real-use.md) |
| 4-way short concurrency | **vLLM** | 1.12x | [2026-08-30-engine-decode-depth](../runs/2026-08-30-engine-decode-depth.md) |
| 4-way deep concurrency | **llama.cpp** | 2.46x | [2026-08-30-engine-decode-depth](../runs/2026-08-30-engine-decode-depth.md) |

The strongest evidence is not a benchmark at all. Server counters over real
traffic show vLLM re-prefilling 27.3 prompt tokens per generated token against
llama.cpp's 2.29, while llama.cpp reached the *deeper* context
([runs/2026-08-31-journal-real-use](../runs/2026-08-31-journal-real-use.md)).
Nobody was benchmarking when that was produced, which is what makes it worth
more than the arms that were staged.

## Concurrency semantics differ structurally

This is a planning constraint, not a tuning knob. vLLM does continuous batching
over a shared paged pool at `--max-num-seqs 4`; a 5th request queues. llama.cpp
uses `-np N` **fixed** slots and **divides** `-c` across them, so max context per
stream is `c/np`, and raising concurrency lowers per-stream context unless total
`-c` (and VRAM) rises.

## Tool calling

Both engines return the parsed OpenAI `tool_calls` shape; neither is
grammar-constrained today.

lemonade proxies `tools` through to llama-server and returns parsed calls rather
than raw text for the client to scrape. Parsing is the model's own template via
`--jinja` (default-enabled on the shipped b1305 build), with
`--reasoning-format auto` separating `reasoning_content`. Verified 2026-08-31
against the loaded Q8XL: `finish_reason: tool_calls`, one well-formed call
returned, and 285 chat completions in that session with zero tool-related errors
in the journal.

vLLM's tool calling runs degraded **on purpose**. The launcher exports
`VLLM_ENFORCE_STRICT_TOOL_CALLING=0` whenever speculation is on, because this
image (2026-06-13) is three weeks short of the upstream fix for vllm#44006 —
with MTP on, the structural tag gets fed the reasoning text and rejects it. Two
costs follow: tool-call syntax is not grammar-guaranteed, and
`tool_choice="required"` or a named function is **silently downgraded to
"auto"**. Measured 2026-08-23: 3/12 requests failed before the workaround, 0/16
after.

Not measured: no A/B of tool-call *correctness* between the two engines has been
run. The reports that lemonade "feels better at tools" are consistent with the
`tool_choice` downgrade above, but they are not evidence.
