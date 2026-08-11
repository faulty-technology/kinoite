# Sourced helpers: package installs that record their own manifest entry, and
# third-party repos that record their own cleanup.
#
# Route every install through install_pkgs. The manifest is not just SBOM
# bookkeeping — bake_sbom runs `rpm -q` over it under `set -e`, so a name that
# doesn't resolve fails the build. Keeping install and record in one call makes
# that an assertion: you can't install something you didn't declare, and you
# can't declare something that didn't install.

MANIFEST=/usr/share/kinoite/packages

# Repo files written during the build, removed again by cleanup.sh. Lives in the
# Containerfile's tmpfs /tmp mount, so it never reaches the image.
REPO_REGISTRY=/tmp/kinoite-repo-files

mkdir -p "$(dirname "$MANIFEST")"

# install_pkgs <pkg>...
install_pkgs() {
    dnf5 install -y "$@"
    printf '%s\n' "$@" >> "$MANIFEST"
}

# install_pkgs_erasing <pkg>...
# For packages that Conflict with the stock Fedora package they displace.
install_pkgs_erasing() {
    dnf5 install -y --allowerasing "$@"
    printf '%s\n' "$@" >> "$MANIFEST"
}

# record_pkgs <pkg>...
# Manifest entry for something installed by other means — an arch-qualified
# install, or a dependency we deliberately depend on by name.
record_pkgs() {
    printf '%s\n' "$@" >> "$MANIFEST"
}

# register_repo_file <path>...
# Mark a .repo file for removal by cleanup.sh.
register_repo_file() {
    printf '%s\n' "$@" >> "$REPO_REGISTRY"
}

# add_copr <slug> <owner/project> <fingerprint> [includepkgs]
# Fingerprint-pins the COPR key, writes the .repo with gpgkey pointed at the
# verified local copy, and registers the file for cleanup. check-keys.sh reads
# these call sites too, so the pin stays checkable.
#
# includepkgs restricts a large COPR to a glob, so it can't upgrade unrelated
# packages out from under us. Anything else resolves from Fedora or fails loudly.
add_copr() {
    local slug="$1" project="$2" fpr="$3" include="${4:-}"
    local owner="${project%%/*}" name="${project##*/}"
    local base="https://download.copr.fedorainfracloud.org/results/${owner}/${name}"
    local repo_file="/etc/yum.repos.d/_copr_${slug}.repo"

    verify_and_import_key "$slug" "COPR ${project}" "${base}/pubkey.gpg" "$fpr"

    cat > "$repo_file" << EOF
[copr:copr.fedorainfracloud.org:${owner}:${name}]
name=Copr repo for ${name} owned by ${owner}
baseurl=${base}/fedora-\$releasever-\$basearch/
type=rpm-md
skip_if_unavailable=False
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-${slug}
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF

    # `if`, not `[ ] &&` — a false test as the last statement would return
    # non-zero and kill the caller under `set -e`.
    if [ -n "$include" ]; then
        printf 'includepkgs=%s\n' "$include" >> "$repo_file"
    fi

    register_repo_file "$repo_file"
}
