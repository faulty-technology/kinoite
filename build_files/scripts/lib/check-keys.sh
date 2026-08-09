#!/bin/bash
# Check every GPG fingerprint pinned in the build scripts against what the
# vendor serves today.
#
# The pins are read straight out of the verify_and_import_key call sites, so
# there is no second list here to drift out of sync — add a new pinned repo
# anywhere under build_files/ and it gets checked automatically.
#
# Usage: ./build_files/scripts/lib/check-keys.sh
# Exit status: 0 if every pin matches, 1 if any drifted.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# gpg needs a writable home; never touch the caller's real keyring.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

# Flatten each pinned-key invocation (backslash continuations and all) onto a
# single "<file>\t<call>" line. Two call forms are pinned:
#   verify_and_import_key <slug> <name> <url> <fpr>...   — URL is literal
#   add_copr <slug> <owner/project> <fpr>                — URL is derived
collect_calls() {
    local f
    while IFS= read -r f; do
        awk -v path="${f#"$REPO_ROOT"/}" '
            /verify_and_import_key|add_copr / && !inblk { inblk = 1; printf "%s\t", path }
            inblk {
                line = $0
                sub(/\\[[:space:]]*$/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                printf "%s ", line
                if ($0 !~ /\\[[:space:]]*$/) { inblk = 0; print "" }
            }
        ' "$f"
    done < <(grep -rlE --include='*.sh' 'verify_and_import_key|add_copr ' "$REPO_ROOT/build_files" \
        | grep -v '/scripts/lib/' | sort)
}

status=0
checked=0

while IFS=$'\t' read -r file call; do
    [ -n "${call:-}" ] || continue
    checked=$((checked + 1))

    pinned=$(grep -oE '\b[0-9A-F]{40}\b' <<< "$call" | sort)

    if [[ "$call" == *add_copr* ]]; then
        # add_copr <slug> <owner/project> <fpr> — reconstruct the COPR key URL.
        project=$(sed -E 's/.*add_copr[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+).*/\1/' <<< "$call")
        name="COPR ${project}"
        url="https://download.copr.fedorainfracloud.org/results/${project}/pubkey.gpg"
    else
        name=$(sed -E 's/.*verify_and_import_key[[:space:]]+"[^"]*"[[:space:]]+"([^"]*)".*/\1/' <<< "$call")
        url=$(grep -oE 'https://[^" ]+' <<< "$call" | head -1)
    fi

    echo "=== ${name} (${file})"

    live=$(curl -fsSL "$url" 2>/dev/null | gpg --show-keys --with-colons 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10}' | sort)

    if [ -z "$live" ]; then
        echo "  FETCH FAILED — $url"
        status=1
    elif [ "$pinned" = "$live" ]; then
        echo "  OK — $(wc -l <<< "$pinned" | tr -d ' ') fingerprint(s) match"
    else
        echo "  MISMATCH — update the pin in ${file} after reviewing the new key"
        diff <(echo "$pinned") <(echo "$live") | sed 's/^/    /'
        status=1
    fi
done < <(collect_calls)

echo
if [ "$status" -eq 0 ]; then
    echo "All ${checked} pinned key(s) match."
else
    echo "Drift detected — see above."
fi
exit "$status"
