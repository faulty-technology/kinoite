# Sourced helper: bake the additive-SBOM TSV from the package manifest.
#
# Each build script appends the packages it installs to
# /usr/share/kinoite/packages; this turns that manifest into the
# NAME<TAB>VERSION-RELEASE<TAB>LICENSE table the CI SBOM/Grype steps consume.
# The marker dir name (/usr/share/kinoite) is intentionally shared by every
# image so the CI extraction path stays constant across profiles.

# rpm -q prints one row per installed *arch*, so a multilib package emits two
# rows with the same NAME — on kinoite-north, steam is an i686 package and drags
# in mesa-vulkan-drivers(x86-32) alongside the x86_64 build that amdgpu.sh
# installs. The CI SBOM keys SPDXIDs on NAME and SPDX requires those to be
# unique, so collapse to one row per name, preferring the 64-bit build
# (reverse arch sort puts x86_64 ahead of noarch ahead of i686).
bake_sbom() {
    rpm -q --queryformat "%{NAME}\t%{VERSION}-%{RELEASE}\t%{LICENSE}\t%{ARCH}\n" \
        $(cat /usr/share/kinoite/packages) \
        | sort -t$'\t' -k1,1 -k4,4r \
        | awk -F'\t' '!seen[$1]++ { print $1 "\t" $2 "\t" $3 }' \
        > /usr/share/kinoite/additive-sbom.tsv
}
