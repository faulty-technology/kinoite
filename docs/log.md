# Update Log

Newest first. One bullet per change to the bundle's structure or metadata; a new
doc gets its family `index.md` line and a bullet here (see
[how-to/maintain-okf-bundle](how-to/maintain-okf-bundle.md)).

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
