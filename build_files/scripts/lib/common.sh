# Sourced by every build script and by both profile orchestrators.
# Single entry point so callers need one path expression, not three.

_KINOITE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$_KINOITE_LIB/verify-key.sh"
. "$_KINOITE_LIB/pkg.sh"
. "$_KINOITE_LIB/sbom.sh"
