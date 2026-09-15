# kinoite-north: radiance Qwen3.8-27B MXFP4 (rootless Quadlet)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`, `r9v.md`,
> `radiance.md`) are here in `/usr/share/kinoite/`.

Qwen3.8-27B in native MXFP4 with the DFlash2 FP8 drafter, served by
radiance-vllm-mxfp4's patched vLLM: TP=2, up to 8 sequences, 262,144-token context.
Ships at /etc/containers/systemd/users/radiance.container, NOT enabled. It cannot
share the GPUs with the other stacks.

    systemctl --user stop north-llm-pod lemonade llamafactory r9v   # free the GPUs FIRST
    systemctl --user start radiance
    journalctl --user -u radiance -f
    curl -s http://127.0.0.1:8005/health

OpenAI API at `http://127.0.0.1:8005/v1`, loopback only and unauthenticated. Model id
`Qwen3.8`; `Qwen3.6` and `Qwen3.8-MXFP4` are aliases. Run
`systemctl --user daemon-reload` first after an OS update.

## The first start is long (this is not a hang)

1. Pulls the pinned image (~9.5 GB) if it is not already here.
2. If anything is missing, `kinoite-radiance-prepare` clones the pinned
   radiance-vllm-mxfp4 commit into ~/.local/share/radiance/src and runs its
   `setup-mxfp4.sh`:
   - ~19 GiB of AMD's MXFP4 release into the shared HuggingFace store;
   - a ~15 min rewrite of its MTP head into ~/.local/share/models/radiance;
   - the 2 GiB DFlash2 drafter;
   - a libr4d build into ~/.local/share/radiance/libr4d.
3. Every start then patches the container's vLLM, compiles radiance's kernel and
   loads the model. That took 210 s to /health with a cold compile cache and 121 s
   warm, in docs/runs/2026-09-15-radiance-mxfp4-dflash.md.

The unit allows two hours for all of it.

## While it runs

- **VRAM:** both cards fill to within about 100 MiB of full.
- **Host RAM:** available RAM bottomed at ~40 GiB under 8 concurrent streams
  (docs/runs/2026-09-15-radiance-mxfp4-dflash.md). Don't start it mid-game.
- **Suspend:** suspend stops it and wake starts it again (kinoite-llm-sleep), so
  expect the start time again.

## Sharing the cards with a smaller model

At the shipped settings it claims both cards whole — 32.5 of 32.6 GiB each — so nothing else can
load. To keep room for a side model, shadow the unit and trade cache for headroom:

    mkdir -p ~/.config/containers/systemd/users
    cp /etc/containers/systemd/users/radiance.container ~/.config/containers/systemd/users/
    # in Exec=: drop `--kv-cache-memory 18563072000`, set `--gpu-memory-utilization 0.55`
    #           and `--max-model-len 131072`
    systemctl --user daemon-reload && systemctl --user restart radiance

That serves one 131,072-token conversation and leaves 14.5 GiB free per card, with decode
unchanged (docs/runs/2026-09-15-radiance-quadlet-floor.md). Start the other model **after**
radiance: each takes its share at startup and holds it. A shadow unit is a full copy, so re-copy
it after an OS update that changes the baked one.

## Freeing disk

AMD's source release is only needed to rebuild the checkpoint:

    rm -rf ~/.local/share/models/huggingface/hub/models--amd--Qwen3.8-27B-Quark-AWQ-MXFP4

## Updating

The image digest and the radiance commit are pinned in
build_files/profiles/north/radiance.sh. After an OS update that changes either,
clear the compile cache, and the checkpoint too if the new commit changes it:

    systemctl --user stop radiance
    rm -rf ~/.local/share/radiance/cache/w4a8-093-gdnm-nqft-fp8s-gnq
    rm -rf ~/.local/share/models/radiance/Qwen3.8-27B-MXFP4-mtpfp8   # only if needed
    systemctl --user start radiance

Measured speed, concurrency and memory: docs/runs/2026-09-15-radiance-mxfp4-dflash.md.
