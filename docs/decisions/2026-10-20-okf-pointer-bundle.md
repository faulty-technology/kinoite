---
date: 2026-10-20
subject: the repo gets an OKF v0.2 pointer bundle at okf/, one thin concept per canonical doc, validated by okflint via a committed manifest
---

# OKF pointer bundle over docs/

## Decision

The repo carries its knowledge in `docs/` (95 files across runs, decisions,
how-to, reference and explanation). Agents consuming it currently have to read
the raw files with no machine-readable metadata. We add an Open Knowledge
Format (v0.2) bundle at `okf/`:

- **One concept per canonical doc**, mirroring the directory layout
  (`okf/runs/`, `okf/decisions/`, …). Each concept is a *pointer*: frontmatter
  (`type`, `title`, `description`, `resource`) plus a one-line body that links
  to the canonical file. No content is copied into the bundle.
- **`okf-base.yaml`** at the repo root is the okflint manifest; conformance is
  `okflint validate --manifest okf-base.yaml`.
- Maintenance rules live in [how-to/maintain-okf-bundle.md](../how-to/maintain-okf-bundle.md).

## Why

OKF's value is a queryable, metadata-rich entry point: an agent can list
concepts, filter by `type`/`tags`, and read one line of description before
deciding to open the full document. Progressive disclosure (`index.md` per
directory) keeps context cost low — the bundle is a table of contents with
frontmatter, not a second copy of the knowledge.

The pointer shape follows directly from this repo's write rules: `runs/` and
`decisions/` are append-only and are the source of truth for measured claims.
A mirrored (copied) bundle would need re-copying on every append and would
drift; a pointer never does. The canonical doc stays the only place content
lives, so the existing rule "the run file is right" is untouched.

## Alternatives rejected

- **Mirror/copy the docs into the bundle.** Duplicates 95 files, breaks on
  every append to `runs/`/`decisions/`, and creates a second source of truth
  this repo's rules explicitly forbid.
- **Convert `docs/` in place (frontmatter on every file).** The doc families
  have their own conventions (append-only history, shipped runbooks that must
  stay self-contained for `/usr/share/kinoite/`). Rewriting them to OKF shape
  would collide with those rules and with the north image's copy of `docs/`.
- **Separate repo for the bundle.** The bundle is a pointer layer over this
  tree; splitting it out means two repos to keep in lockstep for zero gain.
