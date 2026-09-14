# kinoite-north: R9V Qwen3.8 Flash Next (rootless Quadlet)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`, `r9v.md`)
> are here in `/usr/share/kinoite/`.

A 177B MoE served by R9V, a patched vLLM: IQ4_XS with MTP, TP=2, one request at a
time, 131,072-token context. Ships at /etc/containers/systemd/users/r9v.container,
NOT enabled. It cannot share the GPUs with the other stacks.

    systemctl --user stop north-llm-pod lemonade llamafactory   # free the GPUs FIRST
    systemctl --user start r9v
    journalctl --user -u r9v -f
    curl -s http://127.0.0.1:8004/health

OpenAI API at `http://127.0.0.1:8004/v1`, loopback only and unauthenticated.
Model id `qwen3.8-flash-next`. Run `systemctl --user daemon-reload` first after an
OS update.

## The first start is long (this is not a hang)

1. Builds `localhost/kinoite-r9v:latest`: the pinned upstream toolbox image plus a
   one-layer AMD SMI fix. Pulls ~6.4 GB if the base image is not already here.
2. If any model file is missing, downloads the ~90 GiB package and extracts the
   27 GiB embedding table into ~/.local/share/models/r9v/. **This accepts the Qwen
   Community License 1.0 on your behalf.** Allow roughly 45 min, depending on the connection.
3. Loads the model: 472 s with a cold compile cache (~/.local/share/r9v/cache), in
   docs/runs/2026-09-13-r9v-flash-next.md.

The unit allows two hours for all three.

## While it runs

- **Host RAM:** available RAM stays near 24 GiB while it serves and dips to ~17 GiB
  during the load (docs/runs/2026-09-13-r9v-flash-next.md). Don't start it mid-game.
- **Suspend:** suspend stops it and wake starts it again (kinoite-llm-sleep), so expect
  the load time again.

## Updating

The base image is pinned by digest in build_files/profiles/north/r9v.sh. After an
OS update that changes it, rebuild the local image:

    systemctl --user stop r9v
    podman rmi localhost/kinoite-r9v:latest
    systemctl --user start r9v

Measured speed, expert placement and memory: docs/runs/2026-09-13-r9v-flash-next.md.
