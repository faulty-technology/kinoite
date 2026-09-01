---
date: 2026-08-23
subject: run vLLM with strict tool calling disabled rather than bumping to an image that fixes it
---

# Strict tool calling off, image not bumped

## Decision

`VLLM_ENFORCE_STRICT_TOOL_CALLING=0` whenever speculation is on. The image stays
at `:latest` (2026-06-13, vLLM 0.22.1rc1.dev499).

## The bug

Upstream, fixed 2026-07-04 by vllm-project/vllm#44297, which this build predates
by three weeks.

Open WebUI defaults to native function calling, so an ordinary chat carries
`tools`. With strict mode on, the tool parser hands the request an xgrammar
**structural tag** to constrain tool-call syntax. Reasoning models are supposed
to be exempt until the model leaves its thinking block — `should_advance` defers
the FSM advance by one step at the `</think>` boundary — but that deferral has an
explicit escape hatch for speculative decoding plus STRUCTURAL_TAG which returns
True instead. So with MTP on, the FSM is advanced *on* the boundary step and fed
the whole accepted batch, reasoning text and closing tag included:

    backend_xgrammar.py:162 Failed to advance FSM ... for tokens 248069     <- 248069=</think>
    scheduler.py:1531 grammar rejected tokens [10429, 13, 198, 248069]      <- " honest.\n</think>"

Batches are always `1+num_speculative_tokens` long, which is the tell.
Reproduced on-box at 3/12 requests, 0/16 after the workaround. Identical
signature and token id to upstream #44006.

## The alternative, and why it was rejected

An image with the fix exists: kyuz0's `dev` /
`rocm7.14.0-torch2.11.0-vllm0.27.1`, a 2026-08-12 build of vLLM 0.27.1, well
past the fix.

Rejected because 0.27.1 already measured ~15% slower at MTP decode — 34.66 vs
40.75 on an identical prompt
([explanation/vllm-decode-budget](../explanation/vllm-decode-budget.md)).
Upgrading trades 15% of throughput to regain a tool-calling guarantee this box
barely uses.

## What it costs

Tool-call syntax is not grammar-guaranteed, and `tool_choice="required"` or a
named function is **silently downgraded to "auto"**. Calls fall back to the
qwen3_coder parser's `extract_tool_calls` — how vLLM did tool calling before
strict mode existed — so the feature is kept, the guarantee is not.

Only the `tools` path was ever affected. `response_format`/`json_schema` takes
the ordinary deferral and measured clean, as did plain chat.

## The image-bump rule is now three conditions

Post-07-04 fix, **and** not a decode regression, **and** does not reintroduce the
TP=2 hang. The third is new as of 2026-08-30 and exists because RCCL moves as a
side effect of an image bump — see
[explanation/vllm-decode-budget](../explanation/vllm-decode-budget.md#the-upstream-tp2-hang-and-why-this-box-is-a-counter-example).

Verify the third by starting the candidate at TP=2 and watching for the deadlock
signature before benchmarking anything.

Checking tags: `skopeo inspect` the tag rather than trusting the tag list to be
chronological, and compare **digests** before believing two tags are two builds.
As of 2026-08-30, `dev`, `rocm7.14.0-torch2.11.0-vllm0.27.1` and `sha-c5dd87e`
were all one image, digest `sha256:f36940bd…`, created 2026-08-12.
