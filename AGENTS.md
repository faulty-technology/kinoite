# kinoite

Two bootc images from one tree: `kinoite` (laptop) and `kinoite-north` (AMD
9900X, dual Radeon AI PRO R9700, gaming + local LLM). Shell scripts and
Containerfiles; no tests, no package manifest.

## Docs

Four families, distinguished by what you may do to them:

| Path                                               | Write rule                                                                                                                                                                                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/{tutorials,how-to,reference,explanation}/**` | Rewrite in place, freely. Wrong docs get corrected, not appended to. No errata sections, no "update:" notes.                                                                                                                                      |
| `docs/{runs,decisions}/**`                         | Append-only. Never edit, never delete. Create via `scripts/new-run.sh`. Supersede by writing a newer entry that links the old one.                                                                                                                |
| `build_files/**/*.sh` comments                     | Explain the code below them, and nothing else. Measurements, rejected alternatives and decision history move to `docs/runs/` or `docs/decisions/`; the comment carries a link, not the evidence. No errata, no "an earlier version of this said". |
| `CLAUDE.md`, `docs/overview.md`, scratch           | Overwrite constantly. Assumed stale. Disposable.                                                                                                                                                                                                  |

This file is the rule, and it is rewritten in place when the rule changes.
`CLAUDE.md` is a pointer to it and holds nothing.

Read `docs/overview.md` first. It is current but may be wrong. When it
conflicts with a file in `docs/runs/`, the run file is correct and you fix
overview.md in the same turn.

A measured claim in a rewritable doc names the run that produced it:
`48.37 tok/s end-to-end ([runs/2026-08-31-agentic-decode])`. A run that nothing
cites is superseded by definition — that is the whole supersession mechanism.
Never restate a number without its link.

Do not write a document unless one of these happened:

- a run completed and produced results
- a decision was made with alternatives rejected
- an existing doc became factually wrong

Otherwise the answer goes in chat. Most sessions produce zero new files.
No session summaries, no recaps of changes, no restating the diff.

One mode per document. A how-to does not explain. A reference does not teach.
Blending reads as thorough and makes both halves unfindable.

`tutorials/` will likely stay empty. That is correct — this repo has an
operator, not a learner. Do not invent one to fill the slot.

`docs/how-to/{vllm,lemonade,llamafactory}.md` ship to `/usr/share/kinoite/`
and get read on the box with no repo checked out. They stay self-contained:
link out for evidence, never for instructions.

Cross-references name a file and a heading, never a line number.

## Conventions

Measured claims carry a date and a harness. Anything unverified is labelled as
such rather than implied.

`scripts/` is repo tooling and never ships. `build_files/scripts/` runs during
the image build.
