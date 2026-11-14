# Update Log

Newest first. One bullet per change to the bundle's structure or metadata; a new
doc gets its family `index.md` line and a bullet here (see
[how-to/maintain-okf-bundle](how-to/maintain-okf-bundle.md)).

## 2026-11-14

- **New decision**: [decisions/2026-11-14-north-telemetry-alloy-otlp.md](decisions/2026-11-14-north-telemetry-alloy-otlp.md) —
  north pushes radiance `/metrics` and its journal to the nuc's OTel collector from an Alloy agent.
- **Build change**: `build_files/profiles/north/telemetry.sh` ships `/etc/alloy/config.alloy` and
  the enabled system Quadlet `alloy.container`; [how-to/radiance.md](how-to/radiance.md) gains
  "Metrics and logs".

## 2026-11-09

- **New run**: [runs/2026-11-09-north-sunshine-503.md](runs/2026-11-09-north-sunshine-503.md) —
  Moonlight Error 503 on every codec traced to the image drop-in's hard-coded
  `WAYLAND_DISPLAY=wayland-0` while KWin runs on `wayland-1`; superseded same day by
  `/usr/libexec/sunshine-wayland-env`, which resolves a live socket for both Sunshine units.
- **Build change**: `build_files/profiles/north/sunshine.sh` — the pinned `Environment=WAYLAND_DISPLAY`
  is gone from the Sunshine drop-in and from `sunshine-virtual-monitor.service`; both now read
  `EnvironmentFile=-%t/sunshine-wayland.env`.
- **Updated how-to**: [how-to/stream-with-sunshine.md](how-to/stream-with-sunshine.md) —
  added an Error 503 section (startup log → `kscreen-doctor -o` → restart → plug on a dGPU
  port), self-contained for read-on-the-box use.

## 2026-11-08

- **New decision**: [decisions/2026-11-08-drop-r9v.md](decisions/2026-11-08-drop-r9v.md) —
  R9V removed from the north image; `radiance-flash` serves the same model at
  2×+ the decode, 8 sequences and 200K.
- **Removed**: `how-to/r9v.md` (shipped runbook) and its `how-to/index.md` line.
- **New run**: [runs/2026-11-08-radiance-1170-flash-next.md](runs/2026-11-08-radiance-1170-flash-next.md) —
  Qwen3.8 Flash Next on radiance 1.17.0, ad hoc: Polyglot 87.6% against the 27B's
  66–68% (p ≤ 2e-11), LiveCodeBench 68.6% against 64–66%; single-stream decode level
  with the 27B, multi-stream about half.

## 2026-11-07

- **New run**: [runs/2026-11-07-radiance-1170-fp8-vs-mxfp4.md](runs/2026-11-07-radiance-1170-fp8-vs-mxfp4.md) —
  radiance 1.17.0 against 1.8.1 and FP8 against MXFP4, the 10-18 harness at 235 W:
  1.17.0 faster everywhere; FP8 decode 17–36% slower, GSM8K 477 against 480 of 500.
- **New run**: [runs/2026-11-07-radiance-1170-code-fp8-vs-mxfp4.md](runs/2026-11-07-radiance-1170-code-fp8-vs-mxfp4.md) —
  Aider Polyglot and LiveCodeBench, thinking on: FP8 67.6/66.0% against MXFP4
  66.2/64.2%, level; FP8's Polyglot first try 29.8% against 22.2% (p = 0.008).

## 2026-10-29

- **New run**: [runs/2026-10-29-nuc-tev1-systemone.md](runs/2026-10-29-nuc-tev1-systemone.md) —
  Tev1 4B on the same six NUC samples as Clef-flash: 6/6 expected answers,
  1.1–1.6× faster, one scoring pass per question.

## 2026-10-24

- **New run**: [runs/2026-10-24-nuc-clef-flash-systemone.md](runs/2026-10-24-nuc-clef-flash-systemone.md) —
  six `/v1/systemone` samples against Clef-flash on the NUC from the tailnet: 6/6
  expected answers, ~100–118 tok/s prefill, 2.5 s for short calls, 89 s at 6,950 tokens.

## 2026-10-21

- **Migration**: `docs/` became the OKF v0.2 bundle directly. Frontmatter added to
  every doc (metadata only — bodies untouched), one `index.md` per family plus a root
  `index.md`, and this log created. Supersedes
  [decisions/2026-10-20-okf-pointer-bundle.md](decisions/2026-10-20-okf-pointer-bundle.md);
  see [decisions/2026-10-21-docs-is-the-bundle.md](decisions/2026-10-21-docs-is-the-bundle.md).
- **Cutover complete**: `okf/` pointer layer removed; `okf-base.yaml` roots repointed to
  `./docs`; `okflint validate --manifest okf-base.yaml` conformant. The five shipped
  runbooks' `install -D` lines are untouched (frontmatter is inert to their readers).
- **New decision**: [decisions/2026-10-21-drop-libfprint-moc2-custom-build](decisions/2026-10-21-drop-libfprint-moc2-custom-build.md) —
  the custom libfprint-moc2 build chain is removed from the base image; stock floating
  `libfprint` returns.
