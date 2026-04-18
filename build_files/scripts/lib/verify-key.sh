# Sourced helper: verify a vendor GPG key against pinned fingerprints, then import it.
#
# Usage: verify_and_import_key <name> <key_url> <expected_fpr> [<expected_fpr>...]
#
# Pins every fingerprint gpg reports for the key (primary + subkeys). Vendor key
# rotation or added subkeys will fail the build — review the new fingerprint and
# update the caller in a PR.

verify_and_import_key() {
    local name="$1" url="$2"
    shift 2
    local expected
    expected=$(printf '%s\n' "$@" | sort)

    local keyfile gnupg_home actual
    keyfile=$(mktemp)
    # gpg's default ~/.gnupg isn't writable in the base container (no /root),
    # so point it at a throwaway dir.
    gnupg_home=$(mktemp -d)

    curl -fsSL "$url" -o "$keyfile"
    actual=$(GNUPGHOME="$gnupg_home" gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10}' | sort)

    if [ "$expected" != "$actual" ]; then
        echo "$name GPG fingerprint mismatch"
        echo "Expected:"; echo "$expected"
        echo "Actual:";   echo "$actual"
        rm -rf "$keyfile" "$gnupg_home"
        exit 1
    fi

    rpm --import "$keyfile"
    rm -rf "$keyfile" "$gnupg_home"
}
