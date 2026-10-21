# Maintaining the OKF bundle

The `okf/` directory is an [OKF v0.2](https://github.com/GoogleCloudPlatform/open-knowledge-format)
pointer bundle over `docs/`. One thin concept per canonical doc; no content is
ever copied into it. This is how you keep it in sync. See
[decisions/2026-10-20-okf-pointer-bundle.md](../decisions/2026-10-20-okf-pointer-bundle.md)
for why the bundle is a pointer layer rather than a mirror.

## The one rule

**The canonical doc is the content; the concept is metadata plus a link.** If a
fact changes, edit `docs/…` — never `okf/…`. A concept that starts carrying its
own measurements or prose has become a second source of truth and must be cut
back to the template below.

## Adding a concept (when a new doc lands)

1. Create the canonical doc in `docs/<family>/` first (runs via
   `scripts/new-run.sh`; decisions by hand, append-only).
2. Copy the sibling concept's shape — every concept looks like this:

   ```markdown
   ---
   type: Run            # Run | Decision | How-To | Reference | Explanation
   title: "Short human title"
   description: "One line, what this doc is about"
   resource: docs/runs/2026-10-20-example.md
   generated: { by: human:faultytechnology, at: 2026-10-20T12:00:00Z }
   ---

   # Short human title

   One line, what this doc is about.

   Pointer concept: the canonical record is [docs/runs/2026-10-20-example.md](../../docs/runs/2026-10-20-example.md).
   Measurements, decision history and errata live there, not here — keep this file
   to one screen.
   ```

   `type` is the only required field; `title`/`description` are recommended and
   expected here. If the description contains double quotes, use single quotes
   inside so the YAML stays valid.
3. Add one line to the family's `okf/<family>/index.md`:
   `- [Short human title](./2026-10-20-example.md) - <description>`
4. Append a bullet under today's date in `okf/log.md` (newest first).

## Updating a concept

Only its metadata changes: refresh `title`/`description` if the doc's summary
moved, or add `tags`. Never edit the canonical file from here. If the doc was
superseded, leave the old concept in place and note it in the new one's
description — supersession is expressed in `docs/runs/`, not by deleting bundle
files.

## Validating

```bash
okflint validate --manifest okf-base.yaml
```

Exit 0 = conformant. The manifest (`okf-base.yaml`) declares the bundle root
and the reserved filenames; it needs no per-type profile for this bundle. If a
file fails E1/E2 (missing frontmatter or `type`), fix the concept, not the
manifest.

## What the bundle is not

- Not a place for new knowledge — answers go in `docs/` per the repo's doc
  rules, then get a pointer here.
- Not shipped to any image. It lives in the repo only; `/usr/share/kinoite/`
  still carries exactly the five self-contained runbooks it always did.
