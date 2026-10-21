---
type: How-To
title: "Maintaining the OKF bundle"
description: "How to keep docs/ conformant as an OKF v0.2 bundle: give each new doc frontmatter plus a family index line and a log bullet, regenerate indexes with okflint index, and validate with okflint validate."
---

# Maintaining the OKF bundle

`docs/` **is** the [OKF v0.2](https://github.com/GoogleCloudPlatform/open-knowledge-format)
bundle — one file per concept, no mirror, no pointer layer. See
[decisions/2026-10-21-docs-is-the-bundle.md](../decisions/2026-10-21-docs-is-the-bundle.md)
for why the bundle is `docs/` itself rather than a separate `okf/` layer.

## The one rule

**Append-only protects the body; frontmatter is metadata.** A run or decision's
body is never edited after it lands. Its YAML frontmatter (`type`, and for some
families `title`/`description`) is bundle metadata, not content — adding or
refreshing it does not violate append-only. If a fact changes, edit the body per
the family's own write rule; never treat frontmatter as a place to restate it.

## Adding a doc

1. Create the doc in `docs/<family>/` (runs via `scripts/new-run.sh`, which already
   scaffolds `type: Run`; decisions by hand, append-only).
2. Give it frontmatter matching its family:

   ```markdown
   ---
   type: How-To            # Run | Decision | How-To | Reference | Explanation
   title: "Short human title"      # runs/decisions: omit — only `type` is required
   description: "One line, what this doc is about"
   ---
   ```

   `type` is the only required field. For `runs/` and `decisions/` add **only**
   `type` (plus their existing `date`/`subject`/… fields) — do not invent a
   `title`/`description`. For `how-to`, `reference` and `explanation`, derive
   `title` from the first heading and `description` from the first paragraph; if
   that first paragraph is a blockquote, warning or meta-note rather than a
   summary, write a short accurate one instead. If a value contains a colon, wrap
   it in double quotes so the block stays valid YAML.
3. Add one line to the family's `index.md` (regenerable — see below):
   `- [Short human title](./2026-10-21-example.md) - <description>`
4. Append a bullet under today's date in `log.md` (newest first).

## Regenerating indexes

```bash
okflint index --manifest okf-base.yaml --apply
```

This rewrites the five family `index.md` files and the root link list from the
frontmatter. **The root `docs/index.md` is hand-maintained**: it carries the
`okf_version: "0.2"` frontmatter and heading, which the generator strips — so after
an `--apply`, re-add that header (or run the generator only when you will restore
it). Family indexes need no frontmatter.

## Validating

```bash
okflint validate --manifest okf-base.yaml
```

Exit 0 = conformant. If a file fails F001 (frontmatter absent or unparsable), fix
the doc's frontmatter — usually an unquoted `:` in a value — not the manifest. The
manifest (`okf-base.yaml`) declares the bundle root (`./docs`) and the reserved
filenames; it needs no per-type profile for this bundle.

## What the bundle is not

- Not a second copy of the knowledge. There is exactly one file per concept, in
  `docs/`; nothing is mirrored or re-copied on append.
- Not shipped as a whole. No image copies `docs/` wholesale; the five self-contained
  how-tos (vllm, lemonade, llamafactory, r9v, radiance) are installed individually
  via `install -D` to `/usr/share/kinoite/`. YAML frontmatter at the top of a
  markdown file is inert to their readers, so self-containment holds.
