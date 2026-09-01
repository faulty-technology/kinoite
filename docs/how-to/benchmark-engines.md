# Benchmark lemonade against vLLM

The harnesses live in `~/bench/` on the north box. They are not in this repo.
Only one engine can hold the GPUs at a time, so every arm is sequential.

## Run everything

    ~/bench/pc-compare.sh

All three arms (vLLM caching off, vLLM caching on, lemonade), about 30 minutes.
Restores the box on any exit.

## Run one arm

    ~/bench/pcache.sh on|off|status          toggle VLLM_PREFIX_CACHING
    ~/bench/agentic.py <port> <prefix> [base_kb] [turns] [max_tokens] [reps]
    ~/bench/depth.py - 512 3 8000            vLLM decode-vs-depth
    ~/bench/lemctl.py 13305 <model> 512 3    lemonade decode control

Set `BENCH_MODEL=<name>` before `agentic.py` when the target is lemonade. It
lists every *available* model on `/models` rather than the loaded one, so the
usual `data[0]["id"]` idiom picks the wrong model.

## Record the result

    scripts/new-run.sh <slug> '<subject>'

## Toggling prefix caching without root

`pcache.sh` restates the quadlet-generated `ExecStart` with one extra `--env` in
`~/.config/systemd/user/vllm.service.d/`. A `[Service] Environment=` drop-in
does **not** work: the quadlet bakes `Environment=` into the podman argv, so it
sets the variable on the podman client rather than inside the container where
`vllm-serve.sh` reads it. `pcache.sh off` deletes the drop-in and the unit
returns to exactly what the image ships.

## Reading the output

Quote `ms/pass`, not tok/s, when comparing across depths. `depth.py` documents
`ms/pass` as the quantity that is deterministic in depth; tok/s carries
mean-accepted-length noise from speculation and will show differences of a few
percent that are not real.
