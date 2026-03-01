# kinoite

A custom [bootc](https://github.com/bootc-dev/bootc) image based on [Fedora Kinoite](https://fedoraproject.org/kinoite/) 43, built using [ublue-os/image-template](https://github.com/ublue-os/image-template).

The image is published to `ghcr.io/faulty-technology/kinoite:latest` and rebuilt automatically on push via GitHub Actions.

## What's included

On top of the base Fedora Kinoite image:

**Packages**
- `1password` — password manager (via official 1Password repo)
- `distrobox` — container-based development environments
- `google-chrome-stable` — browser (via Google repo)
- `intel-media-driver` — hardware video acceleration
- `lm_sensors` — hardware monitoring
- `podman-compose` — Docker Compose-compatible tooling
- `powertop` — power usage analysis
- `tailscale` — VPN mesh network (via Tailscale repo)
- `rpmfusion-free-release` / `rpmfusion-nonfree-release` — RPM Fusion repos

Third-party repo files are removed after install — updates come from CI image rebuilds rather than live `dnf` updates.

**Enabled services**
- `tailscaled`
- `podman.socket`

**Other changes**
- `/opt` is made immutable (unlinked from `/var/opt`) so packages like Google Chrome persist correctly across deploys.

## Rebasing to this image

From a stock Fedora Kinoite system:

```bash
# First rebase (unverified, to bootstrap)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/faulty-technology/kinoite:latest

# After reboot, switch to the signed image
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/faulty-technology/kinoite:latest
```

Once on the image, you can also use `bootc switch` for future switches since it's a bootc-compatible image:

```bash
bootc switch ghcr.io/faulty-technology/kinoite:latest
```

## Building locally

```bash
just build
```

Requires [just](https://just.systems/) and Podman.

## Repository layout

| Path | Description |
|------|-------------|
| `Containerfile` | Image definition; sets base image and runs `build.sh` |
| `build_files/build.sh` | Package installs, repo setup, and service enables |
| `Justfile` | Local build commands |
| `.github/workflows/build.yml` | CI: builds, pushes, and signs the image by digest |
| `.github/workflows/build-disk.yml` | Manual-only: produces QCOW2/RAW/ISO disk images |
| `disk_config/` | Disk image configuration (QCOW2 and Anaconda ISO) |
| `cosign.pub` | Public key for verifying signed image pushes |
