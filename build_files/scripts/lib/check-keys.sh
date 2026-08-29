#!/bin/bash
# Check every GPG fingerprint pinned in the build scripts against (a) the
# vendored key file under build_files/keys/ and (b) what the vendor serves
# today.
#
# The pins are read straight out of the verify_and_import_key call sites, so
# there is no second list here to drift out of sync — add a new pinned repo
# anywhere under build_files/ and it gets checked automatically.
#
# Vendored check (offline): the file build_files/keys/<slug>.gpg must exist and
# its fingerprints must match the pin. This is what the container build relies
# on at image-build time (see verify-key.sh).
#
# Live check (online): the vendor URL must still serve a key whose fingerprints
# match the pin. A mismatch here means the vendor rotated their key — review
# the new fingerprint, update the pin in the calling script, and re-run
# update-keys.sh to refresh the vendored copy.
#
# Usage: ./build_files/scripts/lib/check-keys.sh
# Exit status: 0 if every pin matches both vendored and live keys, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KEYS_DIR="$REPO_ROOT/build_files/keys"

CURL_RETRY=(--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 15 --max-time 60)

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

fpr_of() {
    gpg --show-keys --with-colons "$1" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10}' | sort
}

status=0
checked=0

while IFS=$'\t' read -r file call; do
    [ -n "${call:-}" ] || continue
    checked=$((checked + 1))

    pinned=$(grep -oE '\b[0-9A-F]{40}\b' <<< "$call" | sort)

    if [[ "$call" == *add_copr* ]]; then
        # add_copr <slug> <owner/project> <fpr> — reconstruct the COPR key URL.
        slug=$(sed -E 's/.*add_copr[[:space:]]+([^[:space:]]+).*/\1/' <<< "$call")
        project=$(sed -E 's/.*add_copr[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+).*/\1/' <<< "$call")
        name="COPR ${project}"
        url="https://download.copr.fedorainfracloud.org/results/${project}/pubkey.gpg"
    else
        slug=$(sed -E 's/.*verify_and_import_key[[:space:]]+"([^"]*)".*/\1/' <<< "$call")
        name=$(sed -E 's/.*verify_and_import_key[[:space:]]+"[^"]*"[[:space:]]+"([^"]*)".*/\1/' <<< "$call")
        url=$(grep -oE 'https://[^" ]+' <<< "$call" | head -1)
    fi

    echo "=== ${name} (${file})"

    # --- Vendored key check (what the build actually consumes) ---
    vendored="${KEYS_DIR}/${slug}.gpg"
    if [ ! -f "$vendored" ]; then
        echo "  VENDORED MISSING — expected ${vendored#$REPO_ROOT/}"
        echo "  Run update-keys.sh to vendor it."
        status=1
    else
        vfpr=$(fpr_of "$vendored")
        if [ "$pinned" = "$vfpr" ]; then
            echo "  VENDORED OK — $(wc -l <<< "$pinned" | tr -d ' ') fingerprint(s) match"
        else
            echo "  VENDORED MISMATCH — file does not match the pin in ${file}"
            diff <(echo "$pinned") <(echo "$vfpr") | sed 's/^/    /'
            status=1
        fi
    fi

    # --- Live drift check (has the vendor rotated since we pinned?) ---
    live=$(curl -fsSL "${CURL_RETRY[@]}" "$url" 2>/dev/null | fpr_of /dev/stdin)

    if [ -z "$live" ]; then
        echo "  LIVE FETCH FAILED — $url (transient? re-run before assuming rotation)"
        status=1
    elif [ "$pinned" = "$live" ]; then
        echo "  LIVE OK — no vendor rotation detected"
    else
        echo "  LIVE MISMATCH — vendor key changed; review and update the pin in ${file},"
        echo "  then run update-keys.sh to refresh the vendored copy"
        diff <(echo "$pinned") <(echo "$live") | sed 's/^/    /'
        status=1
    fi
done < <(collect_calls)

echo
if [ "$status" -eq 0 ]; then
    echo "All ${checked} pinned key(s) match vendored and live sources."
else
    echo "Issues detected — see above."
fi
exit "$status"
