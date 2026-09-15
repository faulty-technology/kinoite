---
date: 2026-09-15
subject: radiance-vllm-mxfp4 (Qwen3.8-27B MXFP4 + DFlash2, R4D, TP2) against same-day lemonade Q8XL and production vLLM FP8: decode versus depth, agentic replay, 8-way concurrency
harness: ~/bench/radiance/all.sh (orchestration), arm.sh (one radiance arm), conc8.py, toolcheck-openai.py and prep.sh; ~/bench/prodab/prodab.sh (production arm) and ~/bench/depth.sh (Q8XL arm); all driving ~/bench/depth.py and ~/bench/agentic.py; raw output ~/bench/radiance/{all,prep}.log, serve-*-0915.log, sampler-*-0915.log, sanity-*-0915.txt, dryrun.txt, ~/bench/prodab/*-prod-0915.* and ~/bench/depth-q8-tensor-mtp-0915.log (off-repo, on the box)
box: kinoite-north
---

# radiance-vllm-mxfp4 against the 27B daily driver

## What was measured

ggz14/radiance-vllm-mxfp4 `9735329` (2026-09-15, VERSION 0.13.0) claims 224 tok/s
single-stream decode for Qwen3.8-27B on 2× R9700, on a code-weighted corpus. It
serves AMD's `amd/Qwen3.8-27B-Quark-AWQ-MXFP4` (`5233554c`) with the MTP head
requantized to FP8 by upstream's `fp8_mtp.py`, and speculates with the DFlash2
drafter `tcclaviger/Qwen3.8-27B-DFlash2-FP8` (`ee0cb26a`).

**Image.** `stilldeadcode/vllm-radiance:0.9.3`, digest `sha256:45694209…`: vLLM
0.27.1, torch 2.11.0+rocm7.14, Triton 3.6.0. At container start the launcher
applies 21 patch scripts from the checkout and compiles a W4A8 GEMM kernel with
hipcc. It also swaps in libr4d `b9e42ab` built with upstream's
`r4d_radiance_extras.patch`.

**Setup.** Upstream's `setup-mxfp4.sh` from the pinned checkout, unchanged. It
downloaded the model, rewrote the MTP head into one 18.04 GiB safetensors file,
fetched the drafter and built libr4d.

**Launch.** Upstream's `serve-mxfp4.sh` with every default except the paths, port
8000 and a trailing `--host 127.0.0.1`:

- DFlash2 at 7 draft tokens, the drafter on TRITON_ATTN,
  `disable_padded_drafter_batch` true, dynamic draft width on;
- `--attention-backend R4D`, `--kv-cache-dtype fp8`;
- `--max-model-len 262144`, `--max-num-seqs 8`, `--max-num-batched-tokens 8192`;
- `--gpu-memory-utilization 0.98` with `--kv-cache-memory 18563072000`, the row
  in upstream's `kv-profiles.tsv` whose signature `2x7551-32624` matches north;
- prefix caching with `mamba-cache-mode align`, `--no-async-scheduling`,
  `qwen-fixed-v22.3.jinja`, the `qwen3_coder` tool parser;
- `--privileged --ipc=host --network=host`.

**Controls.** Both ran the same afternoon, with both cards capped at 250 W.

- **Q8XL.** `depth.sh` with Qwen3.8-27B-UD-Q8_K_XL (`4ca7207`), `-sm tensor -fa on`
  and the Q4_0 MTP draft at `--spec-draft-n-max 4`. This is arm B of
  [runs/2026-09-13-r9v-flash-next](2026-09-13-r9v-flash-next.md) verbatim, but on
  lemonade's current rocm-nightly llama.cpp (`0.4.0-dev`, commit `8172e65`).
- **Production vLLM.** `prodab.sh` with the shipped launcher and image
  (`kyuz0/vllm-therock-gfx1201:latest`, vLLM 0.22.1rc1.dev499): FP8, MTP k=4,
  the drafter on TRITON_ATTN.

**Per arm.** One unit ran the arms back to back: Q8XL, production, radiance, then
radiance again for concurrency. Each vLLM arm got one greedy sanity prompt,
`bench.py 128` as a warm-up, then `depth.py - 512 3 8000`. Radiance also got a
tool-call check (`get_weather`, one non-streaming request) and
`agentic.py 8000 /v1 48 8 256 2`. Thinking was off and temperature 0 throughout,
with decode timed from the first content token to the last.

**Concurrency.** Radiance restarted on the warm cache and ran `conc8.py 8000 384 3`.
That releases eight distinct short prompts together, `ignore_eos`, three reps.

## Numbers

Decode versus depth (`depth.py`, 512 tokens, 3 reps). tok/s is bracketed by min–max
where the spread exceeds 2%.

| point | radiance tok/s | Q8XL tok/s | production tok/s | radiance / Q8XL | radiance / production |
|---|---|---|---|---|---|
| rust (28 tok) | 163.32 | 67.74 | 49.68 | 2.41x | 3.29x |
| python (32 tok) | 228.27 | 73.07 | 59.90 | 3.12x | 3.81x |
| prose (31 tok) | 154.24 | 57.95 | 53.27 | 2.66x | 2.90x |
| control mean | 181.94 | 66.25 | 54.29 | 2.75x | 3.35x |
| 189 | 204.14 | 77.02 | 66.20 | 2.65x | 3.08x |
| 9,479 | 186.87 [179.04–199.05] | 70.07 | 55.36 | 2.67x | 3.38x |
| 37,763 | 185.10 [167.49–185.45] | 62.48 | 42.48 | 2.96x | 4.36x |
| 69,751 | 170.75 | 56.78 | 28.66 | 3.01x | 5.96x |

ms per target pass, with mean accepted length in parentheses:

| point | radiance | Q8XL | production |
|---|---|---|---|
| rust | 21.92 (3.580) | 48.57 (3.290) | 58.77 (2.920) |
| python | 22.08 (5.039) | 48.59 (3.550) | 58.83 (3.524) |
| prose | 21.98 (3.391) | 48.83 (2.830) | 58.96 (3.141) |
| 189 | 22.46 (4.584) | 49.21 (3.790) | 59.39 (3.931) |
| 9,479 | 24.24 (4.529) | 50.95 (3.570) | 67.38 (3.730) |
| 37,763 | 24.04 (4.449) | 56.66 (3.540) | 92.01 (3.908) |
| 69,751 | 26.10 (4.457) | 62.87 (3.570) | 120.59 (3.456) |
| slope, 189 → 69,751 tokens | 0.05 ms per 1K | 0.20 ms per 1K | 0.88 ms per 1K |

Both controls reproduce their records:

- **Q8XL** against 09-13 arm B: the control mean is 66.25 against 65.48, and ms/pass
  differs by −0.34, −0.21, −0.50 and −0.61 at 189, 9,479, 37,763 and 69,751 tokens.
  Acceptance at those points is identical. The 09-13 run does not record its power
  cap, and its llama.cpp was b1328.
- **Production** against the triton arm of
  [runs/2026-09-13-prod-drafter-attention](2026-09-13-prod-drafter-attention.md):
  ms/pass differs by −0.34, −0.09, +0.15 and +0.09 at the same four points. The
  speculative counters match exactly: 4,558 drafts, 11,031 of 18,232 draft tokens
  accepted.

Agentic replay (`agentic.py`, 8 turns, 2 reps, 233,962 prompt tokens). Every turn in
every arm reached the 256-token cap, so the work is equal. The two comparison
columns are the figures recorded in
[runs/2026-08-31-agentic-decode](2026-08-31-agentic-decode.md), not re-measured.

| metric | radiance | lemonade Q8XL (08-31) | vLLM FP8, prefix caching on (08-31) |
|---|---|---|---|
| TTFT turn 1, mean of reps | 1.508 s | 5.992 s | 2.652 s |
| TTFT turns 2+, mean | 0.534 s | 0.980 s | 0.441 s |
| decode median | 326.56 t/s | 67.66 t/s | 48.04 t/s |
| wall median per turn | 1.335 s | 4.724 s | 5.805 s |
| end-to-end | 169.86 tok/s over 24.1 s | 48.37 tok/s over 84.7 s | 41.63 tok/s over 98.4 s |

Radiance's turn 1 TTFT was 2.390 s cold and 0.625 s in rep 2. Its decode climbed
within each conversation, identically in both reps: about 206 t/s on turn 1, 292 on
turn 2, then 326–328 on turns 3–8.

Eight concurrent streams (`conc8.py`):

| rep | decode-agg | wall-agg | wall | per stream |
|---|---|---|---|---|
| 1 | 779.99 | 679.22 | 4.52 s | 86.81–117.10 |
| 2 | 778.67 | 669.44 | 4.59 s | 85.49–116.43 |
| 3 | 771.81 | 650.90 | 4.72 s | 83.68–116.14 |

- Medians: 778.67 tok/s decode-agg and 669.44 tok/s wall-agg.
- Every stream generated its 384 tokens in every rep, on about 5.0 of 24 CPU cores.
- The serve log has no error or traceback lines.
- Counters, warm-up included: 2,493 drafts, 7,139 of 13,681 draft tokens accepted.

Startup and memory:

| | radiance | radiance, concurrency start | Q8XL | production |
|---|---|---|---|---|
| launch to healthy | 210 s, cold compile | 121 s, warm | ~15 s | 101 s |
| peak VRAM per card | 32,528 MiB | 32,523 MiB | 19,479 MiB | 26,681 MiB |
| host MemAvailable minimum | 41,532 MiB | 40,474 MiB | 54,020 MiB | 48,515 MiB |

What radiance's serve log reported:

- **Compile and KV.** `torch.compile` took 19.93 s. Engine init took 82.01 s, of
  which compilation was 36.98 s, and graph capture 8 s. The KV pool held 943,581
  tokens: 3.60x one 262,144-token request.
- **Kernels.**
  - All 304 linear layers ran on radiance's kernel, none forced onto AITER. It is
    logged as W4A8, "not bit-identical" to the checkpoint's W4A4.
  - All 48 GDN layers merged, and the FP8 residual stream spans all 64 layers.
  - R4D resolved 18 of 20 kernel queries. The two misses are the bf16 and w4a16
    `gemm_nt` M=64 kernels, which the pinned libr4d does not build.
- **FP8 KV scale.** `Using KV cache scaling factor 1.0 for fp8_e4m3`.
- **Drafting.** The int2 draft and verify heads armed, and `RADIANCE_DYNAMIC_DRAFT`
  was on. `running the draft eagerly` never appeared, and the thinking-off patch
  applied.

Radiance answered the sanity prompt coherently, with the same substance as
production's answer; the two texts diverge within the first sentence. The tool-call
check returned `finish_reason` `tool_calls`, `get_weather` and
`{"city": "Reykjavik"}`.

## What it means

**Radiance decodes about three times as fast as the Q8XL daily driver at agentic
depth.** At 37,763 and 69,751 tokens it ran 185.10 and 170.75 tok/s against 62.48
and 56.78. The slowest rep at 37,763, 167.49, is still 2.68x. Against production
vLLM the gap widens with depth, from 3.08x at 189 tokens to 5.96x at 69,751.

**Both halves of decode contribute.** Each target pass costs 21.9–26.1 ms against
Q8XL's 48.6–62.9, and DFlash2 at 7 draft tokens accepts 3.4–5.0 tokens per pass
against Q8XL's 2.8–3.8. Which radiance component buys how much of the cheaper pass
(the MXFP4 kernels, R4D attention, the FP8 residual stream, the custom all-reduce)
is not separated by this run.

**Depth nearly stops costing anything.** From 189 to 69,751 tokens radiance adds
0.05 ms per pass per 1K tokens, against 0.20 for Q8XL and 0.88 for production. Why
is not established.

**Upstream's headline is plausible on this box, not reproduced.** The python
control, the most code-like prompt here, ran 228.27 tok/s against the 224 claimed.
Upstream's corpus is different and code-weighted, so this is agreement in kind.

**The agentic replay is 3.51x lemonade's recorded end-to-end, for equal work.**
Warm TTFT of 0.534 s falls between lemonade's 0.980 s and production vLLM's
0.441 s. The 326 t/s decode median reflects this conversation's canned text
drafting well, and is not a general decode figure; the depth series is.

**Eight streams ran clean.** That includes `disable_padded_drafter_batch`, the flag
that crashed production vLLM at three or more concurrent requests
([runs/2026-08-24-drafter-batch-concurrency-crash](2026-08-24-drafter-batch-concurrency-crash.md)).
There was no wedge in three reps.

**The cost is headroom.**
- Radiance fills both cards to within 100 MiB of their 32,624 MiB.
- Host MemAvailable bottoms out 12.5 GiB lower than under Q8XL.
- A cold start takes 210 s.

Not measured:

- output quality: 4-bit MXFP4 weights, W4A8 kernels and an FP8 KV cache at scale
  1.0, against Q8_K_XL. The only checks were one sanity prompt and one tool call,
  and upstream's GSM8K figure was not reproduced
- the de-privileged container posture a quadlet would use; this ran
  `--privileged --network=host`
- concurrency at depth, and any same-day 8-way control for Q8XL or production
- an ablation of radiance's components
- prefix-cache hit rates in the replay
- thinking on
- repeats: one run per arm; the 9,479 and 37,763 spreads exceed 10%
