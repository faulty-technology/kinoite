---
date: 2026-08-31
subject: prompt-token cost of each reasoning_effort level on Qwen3.8-27B through lemonade
harness: curl against the running server on :13305, reading usage.prompt_tokens
box: kinoite-north
---

# What reasoning_effort costs in prompt tokens

## What was measured

Against the running Qwen3.8-27B-Q8XL through lemonade's proxy on :13305. User
message "hi", `max_tokens 1`, reading `usage.prompt_tokens` back.

## Numbers

| setting | prompt tokens |
|---|---|
| nothing set | 53 |
| `xhigh` | 53 |
| `low` | 41 |
| `medium` | **11** |
| bare prompt, for reference | 11 |

## What it means

**An unset knob is not neutral.** Qwen3.8's template resolves
`reasoning_effort|default('xhigh')` — the highest of the three levels — so every
request took the top one by omission.

The template injects a sentence of instruction per level ("Reasoning effort is
set to xhigh. Please think carefully through the task, validate key
assumptions, …"). `medium` is the one level with no elif branch, so it renders
empty. Setting medium adds no budget and no cap; it stops prepending the
think-harder paragraph.

Worth doing because reasoning tokens stay in the context and are re-read on
every later forward pass — thinking is paid for again by every turn after it.

Two traps, both measured:

- The OpenAI-style **top-level** `"reasoning_effort"` field is ignored by this
  llama-server build. It parses, it 200s, and it changes nothing (53 tokens
  either way). Only the nested `chat_template_kwargs` form works.
- `high` is not a fourth level. The GGUF's baked template aliases it onto
  `xhigh`, so it silently means maximum here. That **diverges from the vLLM
  side**, where the template copy has no alias and the same value 400s. Anything
  outside `xhigh|medium|low` raises a Jinja exception and 500s that one request;
  the server survives.

No quality A/B has been run, and none of the throughput tables move — they were
all taken with thinking off.
