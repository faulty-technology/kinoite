# kinoite-north: radiance Qwen3.8-27B MXFP4 (rootless Quadlet)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`, `r9v.md`,
> `radiance.md`) are here in `/usr/share/kinoite/`.

Qwen3.8-27B at MXFP4 with a merged DFlash2 drafter, served by StillDeadcode's
radiance engine (C++/HIP, no vLLM). It runs TP=2, up to 8 sequences, with a
262,144-token context. The trunk is AMD's post-training quantization of the
released model (`amd/Qwen3.8-27B-Quark-AWQ-MXFP4`, Quark with AWQ), byte for byte.
It is not a model trained at 4 bits. Engine and container are pinned in
build_files/profiles/north/radiance.sh.

The unit ships at /etc/containers/systemd/users/radiance.container and is NOT
enabled. It cannot share the GPUs with the other stacks.

    systemctl --user stop north-llm-pod lemonade llamafactory r9v   # free the GPUs FIRST
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

## Switching back to lemonade

The two cannot run at once. Neither is enabled, so either is a command away:

    systemctl --user stop radiance && systemctl --user start lemonade

lemonade serves `127.0.0.1:13305/api/v1` with model id `Qwen3.8-27B-Q8XL`. A
client configured for one needs its base URL and model id changed for the other.

## Freeing disk

The patched-vLLM stack this unit replaced left its files behind. Delete them
once you're sure you won't go back:

    rm -rf ~/.local/share/radiance ~/.local/share/models/radiance
    rm -rf ~/.local/share/models/huggingface/hub/models--amd--Qwen3.8-27B-Quark-AWQ-MXFP4
    podman rmi docker.io/stilldeadcode/vllm-radiance:0.9.3

## Updating

The image digest and the container's revision and sha256 are pinned in
build_files/profiles/north/radiance.sh. A new container replaces the old file in
~/.local/share/models/radiance-engine on the next start. Nothing is compiled at
start, so there is no cache to clear.

Measured speed, quality and concurrency: docs/runs/2026-10-18-radiance-engine-181.md.
