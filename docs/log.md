# Update Log

Newest first. One bullet per change to the bundle's structure or metadata; a new
doc gets its family `index.md` line and a bullet here (see
[how-to/maintain-okf-bundle](how-to/maintain-okf-bundle.md)).

## 2026-10-21

- **Migration**: `docs/` became the OKF v0.2 bundle directly. Frontmatter added to
  every doc (metadata only — bodies untouched), one `index.md` per family plus a root
  `index.md`, and this log created. Supersedes
  [decisions/2026-10-20-okf-pointer-bundle.md](decisions/2026-10-20-okf-pointer-bundle.md);
  see [decisions/2026-10-21-docs-is-the-bundle.md](decisions/2026-10-21-docs-is-the-bundle.md).
- **Cutover complete**: `okf/` pointer layer removed; `okf-base.yaml` roots repointed to
  `./docs`; `okflint validate --manifest okf-base.yaml` conformant. The five shipped
  runbooks' `install -D` lines are untouched (frontmatter is inert to their readers).
