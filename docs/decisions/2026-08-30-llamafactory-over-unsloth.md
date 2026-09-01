---
date: 2026-08-30
subject: LLaMA-Factory replaces Unsloth as the fine-tuning stack
---

# LLaMA-Factory over Unsloth

## Decision

`llamafactory.sh` replaces `unsloth.sh`. The image is built on the box rather
than pulled.

## Why not Unsloth

Unsloth itself worked here — the image built, the gfx1201 filter picked both
R9700s, and torch/triton/bitsandbytes all resolved.

What did not work was **Unsloth Studio**, its no-code UI.
`pip install unsloth[studio]` cannot produce a runnable one: there is no frontend
in the package data, and the CLI gates on a venv that only `unsloth.ai/install.sh`
builds. The documented workaround installs a *second* torch stack, which then
trains on different wheels than the image pins.

LLaMA Board is a plain Gradio app with no installer gate, so the GUI stops being
a caveat.

## Why the image is built on the box rather than pulled

Upstream ships `docker/docker-rocm`, but it bases on
`rocm/pytorch:rocm7.2_ubuntu24.04_py3.12_pytorch_release_2.7.1`, whose gfx1201
coverage is unproven — those images target CDNA first.

What *is* proven on this box is AMD's own whl-multi-arch index, which has a real
gfx1201 target. So the recipe keeps that and swaps only the trainer on top of it.

That is also why `pip freeze` is captured into the image: it is built outside CI,
so the manifest inside it is the only record of what actually landed.
