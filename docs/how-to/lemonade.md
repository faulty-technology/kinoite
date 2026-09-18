# kinoite-north: Lemonade Server (rootless Quadlet)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`) are
> here in `/usr/share/kinoite/`.

Ships at /etc/containers/systemd/users/lemonade.container, NOT enabled.

    systemctl --user daemon-reload      # only after an image update
    systemctl --user start lemonade
    curl -s http://127.0.0.1:13305/live

Web UI and API on http://127.0.0.1:13305 — loopback only, unauthenticated.
To reach it from another machine see "Reaching it from another machine" below;
do not just point a proxy at it, that publishes an API with no credential.
`systemctl --user enable lemonade` is expected to fail: generator-produced units
have no [Install] to act on. That's the guardrail, not a bug.

FIRST START IS SLOW AND LOOKS LIKE A HANG: it pulls a multi-GB image, and the
unit allows 15 minutes (`TimeoutStartSec=900`) for it. Watch it rather than
guessing:

    journalctl --user -u lemonade -f

Loading the first model then downloads the llama.cpp + ROCm bundle (~2.3 GB) into
~/.local/share/lemonade, and the model weights on top of that.

## Recipes (baked custom models)

Curated Qwen and Muse Glimmer GGUFs (Unsloth, plus DavidAU for the -Turbo trio), reconciled into
config/user_models.json on every start.
List and run (via the Web UI, or the CLI inside the container):

    podman exec lemonade lemonade list
    podman exec lemonade lemonade run user.Qwen3.8-27B     # downloads on first run

    user.Qwen3.8-27B             newest dense, vision+thinking, Developer Role    MTP  UD-Q6_K     23.4 GB  ctx 256K
    user.Qwen3.8-27B-Fast        same model, 4-bit — the speed pick               MTP  UD-IQ4_XS   15.6 GB  ctx 256K
    user.Qwen3.8-27B-Q6XL        same model, heavy quant — the quality pick       MTP  UD-Q6_K_XL  25.3 GB  ctx 256K
    user.Qwen3.8-27B-Q8XL        same model, heaviest that still fits the pair    MTP  UD-Q8_K_XL  31.5 GB  256K pool, 4 slots
    user.Qwen3.8-27B-Turbo       uncensored fine-tune, far fewer thinking tokens  MTP  Q6_K        25.0 GB  ctx 256K
    user.Qwen3.8-27B-Turbo-Fast  same fine-tune, 4-bit — the speed pick           MTP  IQ4_XS      18.0 GB  ctx 256K
    user.Qwen3.8-27B-Turbo-Q8    same fine-tune, 8-bit — the quality pick         MTP  Q8_0        31.2 GB  ctx 256K
    user.Qwen3.6-27B             dense, vision+thinking                           MTP  Q6_K        22.9 GB  ctx 128K
    user.Qwen3.6-35B-A3B         fast MoE (~3B active), vision+thinking           MTP  UD-Q6_K     30.0 GB  ctx 128K
    user.Qwen3-Coder-30B         agentic coding MoE, 256K native, text-only       --   Q6_K        25.1 GB  ctx 256K
    user.Muse-Glimmer-30B-Q8XL   Meta's agentic dense 30B, vision+reasoning       DFL  UD-Q8_K_XL  32.3 GB  ctx 128K

### A seeded recipe you cannot see in the Web UI

The model list in the Web UI — and `GET /api/v1/models`, the only model endpoint it calls —
shows DOWNLOADED models only. A recipe that seeded correctly is registered and loadable but
absent from that list until its files are in the cache, which reads exactly like the seeding
having failed. It has not. Check the registry directly instead:

    podman exec lemonade lemonade list                       # everything, with a Downloaded column
    curl -s http://127.0.0.1:13305/api/v1/models/user.Qwen3.8-27B-Q6XL   # 200 = registered

    journalctl --user -u lemonade -b | grep kinoite-lemonade-seed        # what the seeder did

Warm one and it appears:

    podman exec lemonade lemonade pull user.Qwen3.8-27B-Q6XL

"Downloaded" means EVERY component of the recipe — `main`, `draft` and `mmproj`
each have to be in the cache. A main GGUF on disk next to a missing mmproj still
counts as not downloaded, and the model stays out of the list.

Every recipe with an MTP head or a DFlash drafter available uses it (`MTP` or `DFL` in the
table); lemonade turns speculation on by itself and you do not pass any flags.
Qwen3-Coder-30B is the exception: no MTP build exists for it. DFlash is switched on
differently from MTP, see "Muse Glimmer" below.

What actually switches speculation on is the recipe's `mtp` LABEL — lemonade passes
`--spec-type draft-mtp` whenever it sees that label, and passes `--model-draft` only when a
`draft` checkpoint resolves. The two are independent, which is why a recipe whose MTP head
rides inside the main GGUF names no draft file and still speculates. Strip `mtp` from a
recipe's labels and it silently runs unspeculated.

The two Qwen3.6 entries come from the `-MTP-GGUF` sibling repos rather than the plain ones,
at the identical Q6_K filenames — a repo swap, not a requant. Their sizes are ~0.3 GB larger
than the plain builds because the MTP head rides inside the weights.

### The -Turbo trio

`user.Qwen3.8-27B-Turbo*` is DavidAU's decensored, multi-stage Qwen3.8-27B fine-tune
(`...-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP-GGUF`). It answers
prompts the stock seeds refuse, and it spends far fewer tokens thinking before it answers.
Same `qwen35` architecture and the same flags as the stock Qwen3.8 recipes, so it gets
`-sm tensor` and the `reasoning_effort: medium` pin too.

Two knobs that matter here and nowhere else:

- **Keep temperature at or below 1 and repetition_penalty at 1.** Upstream is explicit that
  higher values degrade MTP acceptance; that costs throughput, not just quality.
- **If token acceptance sits below ~50%, the MTP build is the slower choice.** Upstream ships
  plain non-MTP quants of the same model at the same filenames minus the `-MTP-` infix, plus
  reduced-footprint `-LOW-MTP-` IQ4_XS and Q6_K. None is seeded; add one by hand under a new
  name if you need it.

It is not aligned and will not refuse, so the tailnet-exposure warning under "Serving it
makes the API public to your tailnet" applies to this recipe more than to the others.

### Muse Glimmer

`user.Muse-Glimmer-30B-Q8XL` is Meta's Muse Glimmer 30B, a dense agentic model with a vision
encoder, from `unsloth/Muse-Glimmer-30B-GGUF`. The recipe pulls three files, and all three
have to be in the cache before it counts as downloaded, about 38 GB together:

    Muse-Glimmer-30B-UD-Q8_K_XL.gguf       weights
    mmproj-Muse-Glimmer-30B-BF16.gguf      vision encoder
    dflash-kquant.gguf                     DFlash drafter

It speculates with DFlash, not MTP, and lemonade needs two things to turn that on:

- **A `draft` checkpoint whose filename starts with `dflash-`.**
- **The `dflash` label.** Strip it and lemonade does not pass the drafter at all, so the
  model silently runs unspeculated. An `mtp` label does not substitute for it.

`--spec-draft-n-max 15` is set in its `llamacpp_args`. The drafter predicts a block of 16
tokens per pass and llama.cpp's default draft length is 3, which would leave most of each
block unused. Anything above 15 is clamped to 15.

Reasoning is not pinned. The template defaults to `high` when a request sets nothing. Send
`reasoning_effort` (`low`, `medium`, `high` or `xhigh`) per request to change it; llama.cpp
hands it to the template as the reasoning strength. Upstream recommends `high` or `xhigh`
for coding and agentic work.

Upstream's sampling settings are temperature 1.0, top_p 0.95 and top_k 64. Set them in the
client; the recipe does not.

It ships with `-sm tensor -fa on` and the drafter, and both earn their place. Measured on
raw llama-server at ctx 98304, 512 tokens, against the same run's other arms and the
Q8XL daily driver:

    tensor split vs layer split          1.14–1.46x faster at every depth
    DFlash vs no speculation             1.54–2.87x faster at every depth (2.34x at 70K)
    vs user.Qwen3.8-27B-Q8XL             0.89x on the ~30-token control prompts,
                                         1.16x at 191 tokens, 0.88x at 9.5K,
                                         1.09x at 38K, 1.24x at 70K (69.88 vs 56.24 tok/s)

Loaded through lemonade at the shipped ctx 131072, it holds 20.4 GiB on one R9700 and
16.6 GiB on the other. Full tables:
[runs/2026-09-14-muse-glimmer-q8xl-load](../runs/2026-09-14-muse-glimmer-q8xl-load.md).

Qwen3.8-27B is the default all-rounder (MTP + Developer Role); Qwen3-Coder-30B is the
coding workhorse; -Fast trades the Q6 floor for a lighter quant; -Turbo is the uncensored
fine-tune. The seeded ctx values exceed one card: the seven Qwen3.8 recipes split with
`-sm tensor`, the rest use the automatic two-card layer split. All seven sit at 262,144,
which is this checkpoint's native window — they were at half of it until 2026-09-18.

The KV cache is what ctx costs, and on these hybrids it is smaller than the dense
arithmetic suggests: measured on Qwen3.8-27B-Q8XL, doubling ctx from 131,072 to 262,144
added 5.5 GiB PER CARD, so the whole 256K cache is about 22 GiB across the pair, not the
~66 GB a dense 27B would need. Only 16 of 64 layers hold a growing cache (see "Context
size & caching"). Loaded at 262,144 the pair holds 27.0 / 25.8 GiB for Q8XL and 25.0 /
23.9 GiB for Turbo-Q8, both of 31.9 GiB per card. If a recipe does not fit, drop its ctx
or add q8_0 KV-quant. The iGPU is excluded automatically (see "Device visibility").

Throughput figures for MTP and tensor split are in "Performance notes" below; per-quant
numbers in [runs/2026-08-30-quant-sweep](../runs/2026-08-30-quant-sweep.md).

Even more context: add q8_0 KV-quant (-fa -ctk q8_0 -ctv q8_0 in a recipe's llamacpp_args) —
worth up to ~2x on the dense-attention Coder seed, but only ~7.5% measured on a hybrid, see
"Context size & caching". More quality: move a model to Q8_0 in user_models.json. Backend falls back with
`lemonade config set llamacpp.backend=vulkan`.

Recipe seeds are reconciled on EVERY start, so an image update delivers changed recipes on
the next `systemctl --user restart lemonade` — nothing to delete. The image owns the keys it
ships: editing one of the seeded recipes by hand is reverted on the next start, so keep a
tweak by copying it to a new name instead. Keys the image does not ship (anything you added
through the Web UI) are never touched.

config.json is the exception — it is lemonade's own file, seeded from defaults.json on the
FIRST run only, and nothing reconciles it afterwards. Change it with `lemonade config set`.

## Storage

    ~/.local/share/models/huggingface     models (SHARED with vLLM — see vllm.md)
    ~/.local/share/lemonade/llama         llama.cpp + ROCm binaries (downloaded)
    ~/.local/share/lemonade/config        config.json, defaults.json, recipes

The huggingface cache is the shared model store: vLLM and any future stack mount the same
path, so a model pulled by either is reused by both. Owned by you (UserNS=keep-id), so
du/rm/backup tools work normally.

## Reaching it from another machine (tailscale serve)

The server binds loopback only. To use the Web UI from a laptop, front it with
`tailscale serve` on the box:

    tailscale serve --bg 13305    # needs sudo unless `tailscale set --operator=$USER`

lemond refuses any browser Origin that is not loopback, answering 403
`{"error": "Origin not allowed"}`. The page loads and every request it makes
fails, which looks like a broken UI rather than a rejection. The image handles
this: an ExecStartPre reads the box's serve config each start and allows the
origins that proxy to 13305. Restart lemonade after adding or changing a serve
rule — nothing re-reads it while the container runs.

    systemctl --user restart lemonade

Check what it derived:

    journalctl --user -u lemonade | grep kinoite-lemonade-origins
    # kinoite-lemonade-origins: LEMONADE_ALLOWED_ORIGINS=https://<node>.<tailnet>.ts.net

    cat /run/user/$UID/kinoite-lemonade/origins.env   # the file podman reads

Run the derivation by hand without touching the service:

    /usr/libexec/kinoite-lemonade-origins /tmp/origins.env && cat /tmp/origins.env

**AN EMPTY `origins.env` IS NOT A FAILURE, IT IS THE FALLBACK** — it means
loopback-only, exactly as before this existed. Expect it on a box with no serve
rule for 13305. Only `Web` handlers count; a raw `--tcp` forward is not covered.

To set origins by hand — a reverse proxy other than tailscale, or a derivation
that got it wrong — use a Quadlet drop-in. `Environment=` becomes `--env`, which
beats the generated `--env-file`, so this overrides the helper:

    mkdir -p ~/.config/containers/systemd/lemonade.container.d
    cat > ~/.config/containers/systemd/lemonade.container.d/20-origins.conf << 'END'
    [Container]
    Environment=LEMONADE_ALLOWED_ORIGINS=https://proxy.example.com
    END
    systemctl --user daemon-reload && systemctl --user restart lemonade

Values are exact scheme-plus-host, comma-separated for several. `*` allows
everything. Subdomain wildcards like `*.ts.net` match nothing and fail silently.
A drop-in shadows the derivation completely, so delete it once it is not needed
or it will pin a stale hostname. Measured:
[runs/2026-09-03-lemonade-origin-allowlist](../runs/2026-09-03-lemonade-origin-allowlist.md).

### Serving it makes the API public to your tailnet

The loopback bind is what keeps this unauthenticated API private, and a proxy in
front of it reaches the server over loopback like anything else on the box. Once
served, every tailnet node can reach every endpoint with no credential —
including `/internal/mcp/*`, which launches processes. lemond warns about this
only when it BINDS a non-loopback host, so behind a proxy it says nothing.

Set an API key in the same drop-in to close it:

    Environment=LEMONADE_API_KEY=<secret>

`LEMONADE_ADMIN_API_KEY` on its own only covers `/internal/*` and leaves `/api`,
`/v0` and `/v1` open. Clients then send `Authorization: Bearer <secret>`; the Web
UI has a field for it under settings.

## If ROCm dies at model load

Symptom, ~25ms into load_model, before any tensor output:

    Memory critical error by agent node-0 ... Reason: Memory in use.
    llama-server process has terminated with exit code: 134

This is SELinux denying `map` on /dev/kfd, which ROCm mmaps. It looks nothing like a
permission error. Check and fix:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    systemctl status lemonade-selinux.service
    sudo setsebool -P container_use_devices on

lemonade-selinux.service does this at boot; if it's masked or failed, you get the abort.

Tested and does NOT help — don't re-chase: capping ctx_size, `-mg 0 -sm none`,
`--load-mode mmap` alone, `ROCR_VISIBLE_DEVICES`, seccomp=unconfined. `--ipc=host` and
`SecurityLabelDisable=true` DO work, but only because podman drops SELinux label
separation for the container — same fix, bigger hammer.

## Performance notes

Qwen3.8-27B on the R9700 pair. What the seeds ship and what it buys:

    baseline, no speculation, layer split          30.4 tok/s
    + MTP draft head                               56.9 tok/s   (+87%)
    + -sm tensor                                   81.8 tok/s   (+44% on top)

Every seeded recipe that has an MTP head or a DFlash drafter available uses it, and
you do not pass the flags. lemonade adds `--spec-type draft-mtp` itself for any
recipe carrying the `mtp` label, and `--spec-type draft-dflash` for a recipe with
both the `dflash` label and a `dflash-` draft file (see "Recipes" above). Only
`Qwen3-Coder-30B` runs unspeculated, because no MTP build of it exists upstream.

`--spec-draft-n-max 4` is what was measured here. Upstream's general MTP advice
is `n-max 16 --spec-draft-p-min 0.8`, tuned for other models; for Qwen3.8 a large
n-max is reported to cost throughput. Re-measure before changing.

Against vLLM, `-sm tensor` leads at every prompt depth — 1.22x short to 2.61x at
70K — and it leads while reading MORE bytes per token (Q8_K_XL is 31.5 GB
against vLLM's 27.8 GB FP8), so the advantage is the engine, not the quant.
`-sm layer` is the quant-dependent one: fine on IQ4_XS, but it LOSES below
~6-7K context on the heavy quants.

Backend: ROCm. Fall back any time with
`lemonade config set llamacpp.backend=vulkan` — measured ~20% slower, which is
small because both sit near the single-card bandwidth ceiling.

Two things every number here depends on:

- **They are floors.** This build has no RCCL, so every tensor arm ran the slow
  generic butterfly reduction.
- **No quality A/B has ever been run** between IQ4_XS, Q8_K_XL and vLLM's FP8.
  Bits-per-weight is not a quality metric.

Evidence, method and full tables:

    docs/runs/2026-08-20-mtp-speculation.md        the +87%
    docs/runs/2026-08-30-tensor-split.md           the +44.4%, and its four conditions
    docs/runs/2026-08-30-quant-sweep.md            IQ4/Q6/Q8 against vLLM, ms/pass, VRAM
    docs/explanation/llama-cpp-tensor-split.md     why it wins and what it costs
    docs/explanation/quant-selection.md            why the seeds are Q6

### Tensor parallelism: `-sm tensor` works here, `-sm row` is dead

`-sm row` is deprecated upstream and still fails on this build with
`device ROCm0 does not support split buffers`. Both are listed in
`--split-mode`, so the flag being accepted proves nothing.

`-sm tensor` works, subject to four conditions:

1. **`-fa on` is mandatory.** `-fa off` fails at context creation with
   `SPLIT_MODE_TENSOR requires flash_attn to be enabled`.
2. **The iGPU must be excluded.** Automatic since 2026-08-30 — the container
   only ever sees the R9700s. See "Device visibility" below, and "invalid kernel
   file" under "Other gotchas" for the failure it prevents.
3. **`--fit` does not work** under tensor split, so `-c` must be hand-sized. Use
   0.0444 MiB/token/card plus a fixed term that is PER QUANT — 12174 MiB for
   Q6_K_XL with MTP head, ~15623 MiB for Q8_K_XL, the difference being weights.
   Q6_K_XL: `ctx_size 131072` -> ~17.9 GB/card, `262144` -> ~23.8 GB/card.
   Q8_K_XL: ~21.4 and ~27.0 GB/card, both confirmed by loading it.
4. **No RCCL**, so the reduction falls back to the generic butterfly path even
   with exactly two devices. `GGML_CUDA_ALLREDUCE` accepts `internal`/`nccl` but
   neither changes it — this is a build-time opt-in, not a setting.

`-sm tensor` also disables backend sampling, so the MTP draft sampler runs on the
CPU. That is priced into the measured +44.4%.

q8_0 KV-quant composes with it, contradicting upstream's doc: `-sm tensor -fa on
-ctk q8_0 -ctv q8_0` loads, serves and gives identical output, saving 477 MiB
across the pair at ctx 65536. The saving is small for this model because a GDN
hybrid keeps only 16-of-64 full-attention layers — size any expected saving off
the full-attention layer count, not off total context.

To confirm the split:

    podman logs lemonade | grep -iE 'buffer size|assigned|ROCm[0-9]'

### Device visibility: the iGPU is excluded automatically

Since 2026-08-30 the container sees ONLY the R9700s. `lemonade.container` runs an
ExecStartPre that reads KFD topology and writes `ROCR_VISIBLE_DEVICES` into an
EnvironmentFile, which podman passes into the container. Nothing to configure, and no
index is hard-coded — it is recomputed every start.

Check what it derived, in order of how much you have to type:

    journalctl --user -u lemonade | grep kinoite-lemonade-gpus
    # kinoite-lemonade-gpus: gfx_target_version 120001 -> ROCR_VISIBLE_DEVICES=0,1 (of 3 GPU agents)

    cat /run/user/$UID/kinoite-lemonade/gpus.env       # the file podman actually reads
    podman exec lemonade printenv ROCR_VISIBLE_DEVICES # what the server actually got

Run the derivation by hand against the live machine without touching the service:

    /usr/libexec/kinoite-lemonade-gpus /tmp/gpus.env && cat /tmp/gpus.env

The rule it applies: keep every GPU agent whose `gfx_target_version` matches the agent with
the most SIMDs. On this box the two R9700s are 128 SIMDs / 120001 and the iGPU is 4 / 100306,
so the answer is `0,1`. It counts GPU agents in KFD node order and skips CPU agents, which is
exactly how `ROCR_VISIBLE_DEVICES` is indexed, so the index never has to be written down.

**AN EMPTY `gpus.env` IS NOT A FAILURE, IT IS THE FALLBACK.** The helper truncates the file
first and only then fills it in, so anything that goes wrong leaves it empty — and empty means
podman constrains nothing and lemonade starts on layer split exactly as it did before this
existed. That is deliberate: `EnvironmentFile=` becomes `--env-file`, podman treats a MISSING
env file as fatal, so the failure mode had to be "empty" rather than "absent". If you see an
empty file, look for the warning in the journal:

    kinoite-lemonade-gpus: no GPU agent found under /sys/class/kfd/kfd/topology/nodes; ...

To override — a card you want left out, or a derivation that got it wrong — use a QUADLET
drop-in, not `systemctl --user edit`. `systemctl edit` patches the generated .service, which
cannot change the podman command line Quadlet built; a `.container.d` drop-in can:

    mkdir -p ~/.config/containers/systemd/lemonade.container.d
    cat > ~/.config/containers/systemd/lemonade.container.d/10-gpus.conf << 'END'
    [Container]
    Environment=ROCR_VISIBLE_DEVICES=0
    END
    systemctl --user daemon-reload && systemctl --user restart lemonade

That emits `--env` ALONGSIDE the generated `--env-file`, and `--env` wins — verified both
ways on 2026-08-30 (`--env-file` setting `0,1` plus `--env` setting `7` yields `7` in the
container). So the drop-in overrides the derivation without having to disable it.

Two things NOT to do. Do not add `-dev ROCm0,ROCm1` to a recipe's `llamacpp_args` — it covers
the main model only, and every MTP recipe here loads a draft model with its own device list
(see the "invalid kernel file" gotcha). And do not change `EnvironmentFile=%t/...` to `./%t/...`
in the quadlet: podman-systemd.unit(5) suggests that form for specifier paths, but Quadlet then
resolves it against the unit directory and emits a literal `%t` path segment that will never
exist — which, since a missing env file is fatal to podman, is a container that will not start.
Bare `%t` is passed through for systemd to expand. Both forms confirmed with `quadlet -dryrun`.

## Context size & caching

The model download cache is already persistent (see Storage above) — models pull once.
llama.cpp also reuses the KV cache of a request's common prefix automatically; nothing to
configure for that.

The lever for LONG context is VRAM for the KV cache, which is SEPARATE from weights and
grows linearly with ctx_size. MEASURED on Qwen3.8-27B-Q8XL with `-fa on` and `-sm tensor`,
by loading the same recipe at 131,072 and at 262,144: ~0.084 GB per 1K tokens across the
pair, so 128K ~= 11 GiB and 256K ~= 22 GiB, on TOP of the weights. That is about a third
of what the layer arithmetic predicts for a dense 27B, because only 16 of these 64 layers
hold a growing cache and the other 48 are constant-size SSM state. The MoEs are lighter
again, unmeasured here. Even so, a 27B at 256K only fits by SPLITTING across both R9700s,
which is what the seeded contexts assume.

That split is AUTOMATIC here — default -sm layer already spreads layers (and their KV)
across both R9700s and, measured at ctx 32768, put nothing on the gfx1036 iGPU (only its
20 MiB framebuffer). Layer split is what the seeds assume and what is baked. It is NOT the fastest
mode — `-sm tensor` measured +44% on the 27B with MTP (see "Tensor parallelism" above) — but it is
the one that needs no per-recipe arithmetic: tensor split disables `--fit`, so switching a recipe
to it means hand-sizing that recipe's ctx as well. (The iGPU exclusion tensor split also needs is
no longer part of that cost — it is automatic now, see "Device visibility".) One thing to watch at
128K, where total memory is far larger: it must still fit the 2x32 GB pair. Bigger context also
costs prompt-processing time, so a smaller ctx is fine for quick edits.

KV-cache quantization roughly halves that KV footprint with little quality loss. Add to a
recipe's llamacpp_args in recipe_options.json:

    -fa -ctk q8_0 -ctv q8_0     # q8_0 ~halves the GROWING KV; q4_0 ~quarters it

**Flash attention is verified working on gfx1201** (2026-08-30, llamacpp-rocm b1305) and q8_0 K+V
loads and generates correctly, so the old "unverified, confirm -fa first" caveat is retired.

WHAT IS NOT VERIFIED IS THE SIZE OF THE WIN, AND FOR THE HYBRIDS IT IS SMALL. Measured on
Qwen3.5-4B (same qwen35 hybrid family) at ctx 65536: a 477 MiB / ~7.5% saving, because only
16 of 64 layers hold a growing cache and the other 48 are constant-size SSM state that
KV-quant does not touch. It should help more on the dense Qwen3-Coder-30B, which is
unmeasured. See [explanation/quant-selection](../explanation/quant-selection.md).

## Coding / agent use

Two recipes suit agentic coding: user.Qwen3-Coder-30B (tuned for tool-calling / Codex-style
agents, 256K native ctx) and user.Qwen3.8-27B (Developer Role, plus vision + reasoning).
Coder is the default driver — MoE so it's fast, Q6_K, and its native 256K is the seeded
ctx (which the automatic two-card split makes room for).

Point your agent (opencode, aider, Continue, ...) at lemonade's OpenAI-compatible endpoint:

    base URL   http://127.0.0.1:13305/api/v1      (any api key; it's ignored)
    model      user.Qwen3-Coder-30B

Context: agentic coding uses far more than chat (multi-file, diffs, tool output, scratchpad).
The Coder seed is already the native 262144 (256K), which needs the two-card split — see
"Context size & caching". For a quick single-card session, drop ctx or add q8_0 KV-quant.

Keep it warm: an agent resends a large, mostly-unchanged prompt every turn, and llama.cpp
reuses the common prefix's KV automatically — but only while the model stays loaded. Enable
linger (below) and don't let it idle-unload, or you re-process the whole prompt each turn.

### Parallel sub-agents

lemonade starts llama-server with `--parallel 1`, so by default a second request waits for
the first to finish. Only `user.Qwen3.8-27B-Q8XL` is seeded differently: four slots sharing
one 262,144-token KV pool. Four agents on short prompts finish in about half the wall clock
of the same four queued, and each one's first token arrives in ~5 s rather than ~20 s. A
lone request is exactly as fast either way.

At 40K-token prompts the box is prefill-bound and interleaving four cold prefills costs
about what queueing them does. What the pool buys there is residency: four agents' contexts
stay cached at once, so their SECOND turn is where the time comes back.

Check what a loaded model got:

    journalctl --user -u lemonade -b | grep "load_model: initializing"
    # n_slots = 4, n_ctx_slot = 262144, kv_unified = 'true'

The pool is shared, not per slot, and `ctx_size` sizes the whole thing. THE SUM of every
live context has to fit it: four agents at 40K each is fine, four at 70K is not. Exceeding
it kills every stream in flight at once, after they have all paid for their prefill:

    srv decode: Context size has been exceeded
    srv update_slots: decode() failed

A single request larger than the pool is rejected cleanly instead, before any prefill, with
a 400 `exceed_context_size_error`. An over-long prompt therefore fails fast; it is never
served badly. 262,144 is this checkpoint's native window (`qwen35.context_length` in the
GGUF), so nothing is being stretched to reach it — the other Qwen3.8 seeds sit at 131,072,
which is half of what the model does unaided. Going ABOVE 262,144 is what would need YaRN,
and no recipe here configures it.

To give another recipe slots, add to its llamacpp_args in recipe_options.json (the image
reverts edits to the recipes it ships, so copy it to a new name first):

    --parallel 4 --kv-unified

and raise its ctx_size to cover the concurrent sum. Every slot costs KV, not weights: the
Q8XL pool at 262,144 holds 27.0 GiB on one card and 25.8 GiB on the other, against 21.4 /
20.3 GiB for one slot at 131,072. Without `--kv-unified` the pool is split statically
instead — `--parallel 4` alone gives each slot a private quarter — which caps each agent
harder but cannot starve one agent with another's context.

## Other gotchas

### "invalid kernel file" means the iGPU is visible. The llamacpp-rocm build is gfx120X-only
and this box has three ROCm devices — the two R9700s (gfx1201) plus the Granite Ridge
iGPU (gfx1036), for which the build has no kernels. Anything touching every visible
device dies on the first decode.

This hits two paths differently:

    -sm tensor              uses every VISIBLE device -> hits it
    --spec-type draft-mtp   draft model has its own device list, defaulting to all -> hits it
    -sm layer (the default) puts no layers on the iGPU -> never hit

The `-dev` flag only covers the main model, not the MTP draft, so `-dev ROCm0,ROCm1` alone
does NOT fix it. Exclusion at visibility (`ROCR_VISIBLE_DEVICES=0,1`) covers everything.

Re-derive `0,1` rather than trusting it — DRM and device indices move with kernels and slots:

    grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties

120001 is an R9700, 100306 the iGPU; node 0 is the CPU and is not a GPU agent, so subtract
one from the node number to get the agent index. Today: nodes 1,2 = R9700s -> agents 0,1.

The stable ROCm channel has no gfx1201 support and silently falls back to CPU (~7x
slower, no error). The image pins rocm_channel=nightly, but seeds only apply on the
FIRST run; config.json wins after:

    podman exec lemonade lemonade config set rocm_channel=nightly
    podman exec lemonade lemonade backends install llamacpp:rocm

To change device passthrough you must SHADOW the unit, not drop in, since AddDevice=
is a repeated key:

    mkdir -p ~/.config/containers/systemd
    cp /etc/containers/systemd/users/lemonade.container ~/.config/containers/systemd/
    systemctl --user daemon-reload

Note this cannot hide a GPU from ROCm — ROCr enumerates agents from the KFD topology
(/sys/class/kfd/kfd/topology/nodes/), which is global. Use ROCR_VISIBLE_DEVICES.

## SELinux

/dev/dri works out of the box. /dev/kfd is allowed read/write but not `map`, which
ROCm needs. If the server starts but finds no GPU:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    sudo setsebool -P container_use_devices on    # system-wide, all containers

Not baked into the image — setsebool -P state lives in /var/lib/selinux.

## Surviving logout

Already handled — `kinoite-linger.service` runs `loginctl enable-linger` for every regular
account at boot, so a hand-started server outlives the session that started it (including an
SSH session). It cannot be baked as a file: linger is recorded under /var/lib/systemd/linger,
and /var is machine-local state rather than image content, so it is re-asserted each boot.

Confirm with `loginctl show-user $USER -p Linger` (want `Linger=yes`). Note linger starts
nothing by itself: this Quadlet has no [Install] section.

To opt out, `systemctl mask kinoite-linger.service` and then `loginctl disable-linger <user>`.
Doing only the second half does not stick — the service re-asserts linger on the next boot,
which is the whole point of it.

## Suspend / resume

Handled automatically by `kinoite-llm-sleep.service`, the same hook that covers the vLLM stack.
If lemonade was running when the box went to sleep, it will be running again a minute or so after
you wake it; if you stopped it by hand first, it stays stopped.

It is not optional politeness. amdgpu evicts VRAM into system RAM to suspend, and this box has
64 GB of RAM against 64 GB of VRAM across the two R9700s. A loaded model does not fit, and the
result is not a failed suspend but a **hung machine** that needs the power button. lemonade holds
`/dev/kfd` and real VRAM, so it is torn down alongside vLLM.

Full detail, the manual-test recipe that exercises both edges without suspending, and the opt-out
are in `/usr/share/kinoite/vllm.md` under "Suspend / resume".
