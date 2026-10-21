---
type: Decision
date: 2026-10-21
subject: docs/ itself is the OKF v0.2 bundle; the okf/ pointer layer is deleted and superseded
---

# docs/ is the bundle (supersedes the okf/ pointer layer)

Supersedes [decisions/2026-10-20-okf-pointer-bundle.md](./2026-10-20-okf-pointer-bundle.md),
which put an OKF v0.2 *pointer* bundle at `okf/` (one thin concept per canonical
doc, no content copied). That layer is deleted; `docs/` itself becomes the bundle.

## Decision

`docs/` is the OKF v0.2 bundle directly. Every doc carries its own frontmatter
(`type`, plus `title`/`description` where useful); each family directory has an
`index.md`; the root has `index.md` and a `log.md`. Conformance is
`okflint validate --manifest okf-base.yaml`, with the manifest's `roots` pointed at
`./docs`. There is no second copy of the knowledge anywhere.

The pointer layer is removed: `git rm -r okf/`. The five self-contained how-tos
that ship to `/usr/share/kinoite/` (vllm, lemonade, llamafactory, r9v, radiance)
are installed individually via `install -D`; no image copies `docs/` wholesale.

## Why the pointer bundle did not hold up

The 2026-10-20 decision chose a pointer layer to avoid re-copying append-only
families. Three objections to in-place conversion were raised then; each is resolved:

1. **"A pointer bundle is non-distributable."** Correct, and that was the fatal flaw.
   OKF defines the *bundle* as the unit of distribution, but `okf/`'s concepts pointed
   at `resource: docs/runs/…` — a repo-relative path, not a URI — with bodies linking
   `../../docs/…`. Outside the repo those links die, so the bundle could never be shipped
   or handed to another agent on its own. The pointer layer also doubled the maintenance
   surface (95 thin concepts kept in sync with 95 canonical docs) without buying any
   portability.

2. **"A mirror breaks on every append."** Moot — there is no mirror. `docs/` itself *is*
   the bundle: one file, one source of truth. An append to a run or decision needs only
   its frontmatter line (already present) plus one entry in the family `index.md`.
   Nothing is re-copied.

3. **"In-place conversion collides with append-only / shipped runbooks / the north image's
   copy of docs/."** Resolved two ways:
   - **Append-only.** The rule now reads that *append-only protects the body*; YAML
     frontmatter is bundle metadata, not content. The one-time migration adds or extends
     frontmatter only — zero changes to any file's body (verified by diff).
   - **Shipped runbooks / image copy.** Verified: no image copies `docs/` wholesale.
     Exactly five self-contained how-tos are installed individually via `install -D`
     (`build_files/profiles/north/{vllm,lemonade,llamafactory,r9v,radiance}.sh`). YAML
     frontmatter at the top of a markdown file is inert to their readers (systemd
     `Documentation=file://…`, man-page renderers), so self-containment holds.

## What changes

- Frontmatter added across `docs/` (runs, decisions, how-to, reference, explanation,
  overview) — metadata only, bodies untouched.
- `docs/index.md` (root) + one `index.md` per family + `docs/log.md`.
- `okf-base.yaml` roots → `./docs`; reserved filenames unchanged.
- `okf/` deleted.
- New docs carry frontmatter at birth and update their family index + log.

## Alternatives rejected

- **Keep the pointer layer.** Non-distributable (see objection 1) and a doubled maintenance
  surface; it was a table of contents, not a bundle.
- **Mirror/copy docs into a separate bundle.** Rejected in 2026-10-20 and still wrong:
  a second source of truth this repo's rules forbid, re-copied on every append.
