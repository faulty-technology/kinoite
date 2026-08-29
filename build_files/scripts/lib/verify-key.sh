# Sourced helper: verify a vendor GPG key against pinned fingerprints, then import it.
#
# Usage: verify_and_import_key <slug> <name> <key_url> <expected_fpr> [<expected_fpr>...]
#
# Keys are vendored at build_files/keys/<slug>.gpg (visible at /ctx/keys/<slug>.gpg
# during the container build), so the build never depends on the vendor endpoint
# being reachable — a flaky reset from e.g. download.copr.fedorainfracloud.org used
# to fail the whole image build. The pinned fingerprints are still verified against
# the vendored file, so a stale or tampered vendored key fails the build. key_url is
# kept as the documented upstream source: check-keys.sh uses it to detect vendor key
# rotation, and update-keys.sh uses it to refresh the vendored copy.
#
# Pins every fingerprint gpg reports for the key (primary + subkeys). Vendor key
# rotation or added subkeys will fail the build — review the new fingerprint and
# update the caller in a PR.
#
# The verified key is installed to /etc/pki/rpm-gpg/RPM-GPG-KEY-<slug>, and each
# .repo file must point `gpgkey=` at that path. A vendor URL there would let
# `dnf5 -y` auto-import an unpinned key, defeating this check — keep it file://.

verify_and_import_key() {
    local slug="$1" name="$2" url="$3"
    shift 3
    local expected
    expected=$(printf '%s\n' "$@" | sort)

    local keys_dir vendored gnupg_home actual
    keys_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../keys" 2>/dev/null && pwd)"
    vendored="${keys_dir}/${slug}.gpg"

    if [ ! -f "$vendored" ]; then
        echo "$name: vendored key missing at build_files/keys/${slug}.gpg (upstream: $url)" >&2
        echo "Run build_files/scripts/lib/update-keys.sh to vendor it." >&2
        exit 1
    fi

    # gpg's default ~/.gnupg isn't writable in the base container (no /root),
    # so point it at a throwaway dir.
    gnupg_home=$(mktemp -d)
    actual=$(GNUPGHOME="$gnupg_home" gpg --show-keys --with-colons "$vendored" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10}' | sort)

    if [ "$expected" != "$actual" ]; then
        echo "$name GPG fingerprint mismatch (vendored key at ${vendored})"
        echo "Expected:"; echo "$expected"
        echo "Actual:";   echo "$actual"
        echo "If the vendor rotated their key, review it and re-run update-keys.sh."
        rm -rf "$gnupg_home"
        exit 1
    fi

    install -Dm0644 "$vendored" "/etc/pki/rpm-gpg/RPM-GPG-KEY-${slug}"
    rpm --import "$vendored"
    rm -rf "$gnupg_home"
}
