# Sourced helper: bake the additive-SBOM TSV from the package manifest.
#
# Each build script appends the packages it installs to
# /usr/share/kinoite/packages; this turns that manifest into the
# NAME<TAB>VERSION-RELEASE<TAB>LICENSE table the CI SBOM/Grype steps consume.
# The marker dir name (/usr/share/kinoite) is intentionally shared by every
# image so the CI extraction path stays constant across profiles.

# rpm -q prints one row per installed arch and the CI SBOM keys SPDXIDs on NAME
# alone, so a multilib package (steam drags in mesa-vulkan-drivers.i686) would
# emit a duplicate SPDXID. Keep one row per name, preferring the 64-bit build.
bake_sbom() {
    rpm -q --queryformat "%{NAME}\t%{VERSION}-%{RELEASE}\t%{LICENSE}\t%{ARCH}\n" \
        $(sort -u "$MANIFEST") \
        | sort -t$'\t' -k1,1 -k4,4r \
        | awk -F'\t' '!seen[$1]++ { print $1 "\t" $2 "\t" $3 }' \
        > /usr/share/kinoite/additive-sbom.tsv
}
