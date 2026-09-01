#!/bin/bash
set -euo pipefail

# Scaffolds an append-only run record under docs/runs/. See CLAUDE.md "Docs":
# runs are never edited and never deleted, so this refuses to touch an existing
# file rather than offering to overwrite one.

usage() {
    echo "usage: ${0##*/} <slug> [subject]" >&2
    echo "  ${0##*/} agentic-decode 'lemonade vs vLLM, multi-turn'" >&2
    exit 2
}

[ $# -ge 1 ] || usage

slug="$1"
subject="${2:-}"

case "$slug" in
    *[!a-z0-9-]* | -* | *- | "")
        echo "slug must be lowercase alphanumeric and dashes: $slug" >&2
        exit 1
        ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
out="$REPO/docs/runs/$(date +%F)-$slug.md"

if [ -e "$out" ]; then
    echo "exists, and runs are append-only: ${out#"$REPO"/}" >&2
    exit 1
fi

# The harnesses live off-repo in ~/bench/ on the box and are not
# version-controlled, so the record names one rather than pinning a commit.
cat > "$out" << EOF
---
date: $(date +%F)
subject: ${subject:-<one line>}
harness: <script name, and where it lives>
box: kinoite-north
---

# ${subject:-<title>}

## What was measured

## Numbers

## What it means
EOF

echo "${out#"$REPO"/}"
