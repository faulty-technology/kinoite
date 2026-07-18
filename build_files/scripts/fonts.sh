#!/bin/bash
set -ouex pipefail

### Deterministic fontconfig caches
# fontconfig caches embed the mtime of each font directory, but ostree deploys
# every file with mtime 0. Caches generated during the container build (real
# mtimes) therefore never validate on the deployed system, so fontconfig falls
# back to regenerating per-user caches in ~/.cache/fontconfig — which go stale
# on the next image update and render glyphs as squares until manually cleared.
#
# Normalizing all font mtimes to epoch before rebuilding the system caches
# makes the baked caches match the deployed filesystem exactly.
find /usr/share/fonts -exec touch -h -d '@0' {} +
fc-cache --system-only --really-force
