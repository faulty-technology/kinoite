---
date: 2026-08-31
subject: vLLM ships with prefix caching on by default
---

# vLLM prefix caching defaults to on

## Decision

`VLLM_PREFIX_CACHING` defaults to true in `vllm.sh`. It was opt-in before.

## Why

1.73x end-to-end on the agentic arm with no measurable decode cost
([runs/2026-08-31-agentic-decode](../runs/2026-08-31-agentic-decode.md)). With
caching off, TTFT climbed monotonically with turn number — the agent got slower
the longer you talked to it. The `ms/pass` table in that run shows the apparent
-2.6% decode penalty is acceptance-length drift, not a real cost.

## What this does not settle

The reason it was opt-in is still live and this decision does not answer it.
Upstream gates prefix caching for hybrid models — `is_prefix_caching_supported`
returns False for `attn_type == "hybrid"`, logged at DEBUG — and Qwen3.8-27B is
`qwen3_5`, i.e. hybrid. So the default overrides an experimental gate.

That is a correctness question and no throughput number bears on it. Correctness
spot-checks passed 2026-08-22 and nothing since has contradicted them, but the
flag has never been quality-A/B'd on versus off.

## Revert

`VLLM_PREFIX_CACHING=false` is the single revert.
