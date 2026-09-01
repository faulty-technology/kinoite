# When a build fails on a GPG mismatch

Vendor keys are fingerprint-pinned in the calling scripts and vendored under
`build_files/keys/`. A vendor rotating a key breaks the build.

Diff the pins against the live vendor keys:

    build_files/scripts/lib/check-keys.sh

It exits nonzero on drift and names which key moved. Update the vendored blob and
the pin together — `build_files/scripts/lib/update-keys.sh` refreshes the blobs.

Six pins are covered: bazzite-org, pvermeer/sunshine, ilyaz/LACT, 1Password,
Google Chrome (x9), Tailscale (x2).
