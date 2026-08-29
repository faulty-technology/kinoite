#!/bin/bash
# Re-vendor the GPG keys under build_files/keys/ from the vendor URLs pinned in
# the build scripts.
#
# For each verify_and_import_key / add_copr call site this:
#   1. downloads the key from the vendor URL,
#   2. verifies its fingerprints against the pin in the calling script,
#   3. only on match, writes build_files/keys/<slug>.gpg,
#   4. on fingerprint mismatch, exits non-zero and prints the new fingerprints
#      so a human can review and bump the pin in the same PR.
#
# Usage: ./build_files/scripts/lib/update-keys.sh
# Exit status: 0 if every vendored key was refreshed, 1 if any fetch failed or
#              any fingerprint mismatched the pin.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KEYS_DIR="$REPO_ROOT/build_files/keys"
mkdir -p "$KEYS_DIR"

CURL_RETRY=(--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 15 --max-time 120)

# gpg needs a writable home; never touch the caller's real keyring.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

# Same collection logic as check-keys.sh: flatten each pinned-key invocation
# (backslash continuations and all) onto a single "<file>\t<call>" line.
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

while IFS=$'\t' read -r file call; do
    [ -n "${call:-}" ] || continue

    pinned=$(grep -oE '\b[0-9A-F]{40}\b' <<< "$call" | sort)

    if [[ "$call" == *add_copr* ]]; then
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

    tmp=$(mktemp)
    if ! curl -fsSL "${CURL_RETRY[@]}" "$url" -o "$tmp" 2>/dev/null; then
        echo "  FETCH FAILED — $url (existing vendored key left in place)"
        rm -f "$tmp"
        status=1
        continue
    fi

    live=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10}' | sort)

    if [ "$pinned" != "$live" ]; then
        echo "  FINGERPRINT MISMATCH — review the new key, bump the pin in ${file},"
        echo "  then re-run this script to vendor the new key."
        echo "  Pinned:"; sed 's/^/    /' <<< "$pinned"
        echo "  Live:";   sed 's/^/    /' <<< "$live"
        rm -f "$tmp"
        status=1
        continue
    fi

    install -Dm0644 "$tmp" "$KEYS_DIR/${slug}.gpg"
    rm -f "$tmp"
    echo "  VENDORED — keys/${slug}.gpg ($(wc -l <<< "$pinned" | tr -d ' ') fingerprint(s) verified)"
done < <(collect_calls)

echo
if [ "$status" -eq 0 ]; then
    echo "All keys re-vendored successfully."
else
    echo "Issues detected — see above."
fi
exit "$status"
