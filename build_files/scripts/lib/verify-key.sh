# Sourced helper: verify a vendor GPG key against pinned fingerprints, then import it.
#
# Usage: verify_and_import_key <slug> <name> <key_url> <expected_fpr> [<expected_fpr>...]
#
# Pins every fingerprint gpg reports for the key (primary + subkeys). Vendor key
# rotation or added subkeys will fail the build — review the new fingerprint and
# update the caller in a PR.
#
# On success the verified key is also installed to
# /etc/pki/rpm-gpg/RPM-GPG-KEY-<slug> so the matching .repo file can point
# `gpgkey=` at that file:// path instead of the vendor URL. With a URL there,
# `dnf5 -y` would silently fetch and auto-import whatever key the vendor serves
# if a package were signed by something not already in the rpmdb — routing
# around this pin. A file:// key leaves dnf no unpinned key to reach for, and
# still satisfies repo_gpgcheck=1 (which verifies repomd.xml against the
# repo's configured key, not the rpmdb).

verify_and_import_key() {
    local slug="$1" name="$2" url="$3"
    shift 3
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

    install -Dm0644 "$keyfile" "/etc/pki/rpm-gpg/RPM-GPG-KEY-${slug}"
    rpm --import "$keyfile"
    rm -rf "$keyfile" "$gnupg_home"
}
