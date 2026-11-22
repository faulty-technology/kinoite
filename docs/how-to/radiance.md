---
type: How-To
title: "kinoite-north: radiance Qwen3.8-27B MXFP4 (rootless Quadlet)"
description: "Rootless Quadlet serving Qwen3.8-27B at MXFP4 with a merged DFlash2 drafter via StillDeadcode's radiance engine (C++/HIP, no vLLM): TP=2, up to 8 sequences, 262k context; the model is AMD's Quark/AWQ post-training quantization of the released model. Four alternates serve the same port and model id: radiance-fp8 (27B FP8), radiance-flash (Qwen3.8 Flash Next, the 177B MoE, 200k context), radiance-flash2 (Flash Next as IQR-V4 on radiance 2.2.0) and radiance-iq8 (27B as IQ8R on radiance 2.2.0). Ships at /etc/containers/systemd/users/radiance{,-fp8,-flash,-flash2,-iq8}.container, not enabled."
---

# kinoite-north: radiance Qwen3.8-27B MXFP4 (rootless Quadlet)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`,
> `radiance.md`) are here in `/usr/share/kinoite/`.

Qwen3.8-27B at MXFP4 with a merged DFlash2 drafter, served by StillDeadcode's
radiance engine (C++/HIP, no vLLM). It runs TP=2, up to 8 sequences, with a
262,144-token context. The trunk is AMD's post-training quantization of the
released model (`amd/Qwen3.8-27B-Quark-AWQ-MXFP4`, Quark with AWQ), byte for byte.
It is not a model trained at 4 bits. Engine and container are pinned in
build_files/profiles/north/radiance.sh.

The unit ships at /etc/containers/systemd/users/radiance.container and is NOT
enabled. It cannot share the GPUs with the other stacks.

    systemctl --user stop north-llm-pod lemonade llamafactory   # free the GPUs FIRST
    systemctl --user start radiance
    journalctl --user -u radiance -f
    curl -s http://127.0.0.1:8005/health

The OpenAI API is at `http://127.0.0.1:8005/v1`, loopback only and
unauthenticated. An `Authorization` header is accepted and ignored. The model id
is `Qwen3.8`, and a request naming any other model is served by it too. Run
`systemctl --user daemon-reload` first after an OS update.

The engine also serves `/v1/messages` (Anthropic), `/metrics`, `/stats`,
`/sessions` (what the prefix cache holds) and `/diagnostics` (every option, where
its value came from, and what on this box costs speed).

## The first start downloads 19 GB

1. Pulls the pinned image if it is not already here.
2. `kinoite-radiance-prepare` downloads the pinned `qwen3.8-27b-mxfp4.rad` into
   ~/.local/share/models/radiance-engine and checks its sha256. A later start
   skips both.
3. Loads the model. A warm start is serving in about 20 s
   (docs/runs/2026-10-18-radiance-engine-181.md).

The unit allows two hours for all of it.

## While it runs

- **VRAM:** both cards are taken whole. The KV pool is 1,268,272 tokens
  (docs/runs/2026-10-08-radiance-engine-v1-vs-vllm-radiance.md).
- **Pinned host RAM:** about 18 GiB stays pinned for the life of the server:
  - the token embedding, 1.18 GiB per card;
  - the linear-state snapshot store, 7.49 GiB, sized automatically;
  - the 8 GiB prefix-cache host tier.

  Pinned memory cannot be swapped. Don't start it mid-game.
- **Suspend:** suspend stops it and wake starts it again (kinoite-llm-sleep). The
  prefix cache is lost across that.
- **Cache expiry:** a conversation no request has used for an hour leaves the
  cache (`--prefix-cache-ttl`, default 3600).

## Metrics and logs

`alloy.service` (a system unit, enabled) scrapes `/metrics` every 15 s and
tails the journal, then pushes both to the nuc's collector at `http://nuc:31432`.
Nothing to start. In the nuc's Grafana:

- **Metrics:** the radiance dashboard, or `{job="radiance", instance="north"}`
  in Prometheus. `up` is 0 while no radiance unit runs. The series carry no
  unit label: every unit is `job="radiance"`, so tell them apart by time, or by
  `radiance:kv_cache_max_tokens`, which differs per unit.
- **Logs:** `{service_namespace="north", service_name="radiance.service"}` in
  Loki. Swap in `radiance-fp8.service`, `radiance-flash.service`,
  `radiance-flash2.service` or `radiance-iq8.service` for the others.

Check the agent:

    systemctl status alloy
    journalctl -u alloy -f
    curl -s http://127.0.0.1:12345/-/ready

## Thinking, and what clients may send

Thinking is controlled per request. When a request sets nothing, the unit defaults
to `medium`, the level lemonade pins on its Qwen3.8 recipes. The engine's own
default is `xhigh`.

    "reasoning_effort": "low" | "medium" | "xhigh"
    "reasoning_effort": "none"                                # thinking off
    "chat_template_kwargs": {"enable_thinking": false}        # same thing

Things that differ from other OpenAI servers:

- **Reasoning text arrives in `message.reasoning_content`.**
- **Only some effort levels are accepted.** `high` and `max` are mapped to `xhigh`,
  and `minimal` to `low`. Any other level is refused with HTTP 400, which names
  the levels it accepts.
- **`none` works only at the top level.**
  `"chat_template_kwargs": {"reasoning_effort": "none"}` is refused with HTTP
  400. Use top-level `reasoning_effort` or `enable_thinking` instead.

Unset sampling fields default to temperature 0.7, top-p 0.95 and top-k 20. A
request that names a field keeps its own value. `curl -s
127.0.0.1:8005/server_info` lists every effective default under
`request_defaults`.

## The other four units

Four more units serve the same port and model id `Qwen3.8`, so a client needs no
change. All five conflict, so starting one stops whichever is running:

    systemctl --user start radiance-fp8      # or radiance-flash, radiance-flash2, radiance-iq8
    journalctl --user -u radiance-fp8 -f
    systemctl --user start radiance          # and back

Each downloads its own file into ~/.local/share/models/radiance-engine on first
start, beside the others.

**`radiance-fp8`**: the 27B at FP8 (`qwen3.8-27b-fp8.rad`), with the same
DFlash2 drafter and the same flags as `radiance`.
- **The first start downloads 31 GB.**
- **Decode is 17–36% slower** than MXFP4.
- **The KV pool is smaller:** 1,025,408 tokens against 1,375,232.
- **Code scores are level** with MXFP4. It gets more Polyglot exercises right on
  the first try (docs/runs/2026-11-07-radiance-1170-code-fp8-vs-mxfp4.md).

**`radiance-flash`**: Qwen3.8 Flash Next, the 177B MoE
(`qwen3.8-next-flash-fp8-iq4r-moe.rad`), with 4-bit experts, an int8 trunk and
MTP drafting. Its flags are its model card's.
- **The first start downloads 122 GB.** Allow about 45 minutes, plus about a
  minute for the checksum.
- **It needs host RAM.** 12 GiB of experts stay pinned in host memory. Expect
  about 20 GiB available while it serves. Don't start it mid-game.
- **The context is 200,000 tokens,** not 262,144.
- **One request at a time is as fast as MXFP4,** and does not slow with depth.
  Prefill is 1.4–2.1× faster.
- **Several requests at once are slower:** about 50–60 tok/s each, about half
  of MXFP4's combined throughput.
- **It wrote better code** in the benches: Aider Polyglot 87.6% against 66–68%
  (docs/runs/2026-11-08-radiance-1170-flash-next.md).
- **Thinking, sampling and the API are the same** as `radiance` above.

**`radiance-flash2`**: the same Flash Next on radiance 2.2.0, as
`qwen3.8-next-flash-iqr-v4.rad` (IQR-V4 experts). 2.x refuses the other units'
files, so this unit has its own image and file.
- **The first start downloads 122 GB,** as `radiance-flash`, and it needs the
  same 12 GiB of pinned host RAM.
- **Its settings are a YAML file,** `/etc/radiance/radiance-flash2.yaml`, not
  flags: `radiance-flash`'s, with the int8 KV cache (2.x has no fp8 one) and a
  4 GiB host tier for the prefix cache.
- **Earlier turns' reasoning is dropped:** `chat-template-kwargs:
  {preserve_thinking: false}`. The template keeps only the reasoning from after
  the latest user message, which is the current tool chain. Without it, every
  turn's reasoning that a client sends back stays in the prompt. pi sends all
  of it. To restore that, delete the line from the YAML and restart the unit.
- **Drafting uses 2.2.0's speculative options:** `draft-coupling: on`,
  `draft-verify: traversal`, `draft-depth: adaptive` (1 to
  `num-speculative-tokens: 5` drafts a step) and `draft-suffix: on`. Upstream
  says none changes the output distribution. Requests at temperature 0 bypass
  coupling and the verify modes. Draft acceptance in the metrics is not
  comparable with the earlier fixed chain of 3. The startup log shows what
  runs: `journalctl --user -u radiance-flash2 | grep -iE 'coupled|draft depth|draft suffix'`.
- **Its KV pool is smaller than `radiance-flash`'s.** The engine prints it at
  start: `journalctl --user -u radiance-flash2 | grep 'kv: the pool'`.
- **Code scores are level** with `radiance-flash`, and it decoded about 1.8×
  faster per stream in real use, both measured on 2.1.0
  (docs/runs/2026-11-19-radiance-210-flash-iqr-code.md). 2.2.0 is not
  measured here.
- **Thinking, sampling and the API are the same** as `radiance` above, except
  that 2.x answers only to the model id `Qwen3.8`; 1.17.0 accepts any name.

**`radiance-iq8`**: the 27B on radiance 2.2.0, as
`qwen3.8-27b-iq8r-dflash.rad`: a rotated int8 trunk with an int8 DFlash2
drafter. It is the 2.x counterpart of `radiance-fp8`, which 2.x cannot load.
- **The first start downloads 31 GB.**
- **Its settings are a YAML file,** `/etc/radiance/radiance-iq8.yaml`:
  `radiance`'s window and sequences, the int8 KV cache and an 8448 MiB host
  tier for the prefix cache.
- **On 2.1.0 it was slower than MXFP4 on 1.17.0:** prefill 7–12% and decode
  20–38%. GSM8K was level (docs/runs/2026-11-18-radiance-210-iqr-vs-1170-mxfp4.md).
  Code is not benched.
- **Thinking, sampling and the API are the same** as `radiance-flash2`.

Delete a file once you're done with that unit:

    rm ~/.local/share/models/radiance-engine/qwen3.8-27b-fp8.rad*
    rm ~/.local/share/models/radiance-engine/qwen3.8-next-flash-fp8-iq4r-moe.rad*
    rm ~/.local/share/models/radiance-engine/qwen3.8-next-flash-iqr-v4.rad*
    rm ~/.local/share/models/radiance-engine/qwen3.8-27b-iq8r-dflash.rad*

## Switching back to lemonade

These cannot run at once. None is enabled, so each is a command away:

    systemctl --user stop radiance radiance-fp8 radiance-flash radiance-flash2 radiance-iq8 && systemctl --user start lemonade

lemonade serves `127.0.0.1:13305/api/v1` with model id `Qwen3.8-27B-Q8XL`. A
client configured for one needs its base URL and model id changed for the other.

## Updating

The image digest and the container's revision and sha256 are pinned in
build_files/profiles/north/radiance.sh, for each unit. A new container replaces the old file in
~/.local/share/models/radiance-engine on the next start. Nothing is compiled at
start, so there is no cache to clear.

Measured speed, quality and concurrency: docs/runs/2026-10-18-radiance-engine-181.md.
