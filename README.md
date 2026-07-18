# kinoite

A custom [bootc](https://github.com/bootc-dev/bootc) image based on [Fedora Kinoite](https://fedoraproject.org/kinoite/) 44, built using [ublue-os/image-template](https://github.com/ublue-os/image-template).

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
- `nix` / `nix-daemon` — [Nix](https://nixos.org/) in multi-user mode (modern CLI + flakes; no legacy `nix-*` commands). User packages are managed declaratively via a separate home-manager flake; the store persists in `/var/nix`, bind-mounted onto `/nix` at boot.

Third-party repo files are removed after install — updates come from CI image rebuilds rather than live `dnf` updates.

**Enabled services**
- `tailscaled`
- `podman.socket`
- `nix-daemon.socket` (+ `var-nix.service` / `nix.mount` for the persistent `/nix` store)

**Other changes**
- `/opt` is made immutable (unlinked from `/var/opt`) so packages like Google Chrome persist correctly across deploys.
- Font mtimes are normalized to epoch and system fontconfig caches rebuilt at image build time, so caches validate on the deployed (mtime-0) ostree filesystem instead of going stale per-user.

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

## Building

Images are built, signed, and pushed by GitHub Actions on every push to `main`.
For a one-off local build: `podman build -t kinoite .`

## Repository layout

| Path | Description |
|------|-------------|
| `Containerfile` | Image definition; sets base image and runs `build.sh` |
| `build_files/build.sh` | Package installs, repo setup, and service enables |
| `.github/workflows/build.yml` | CI: builds, pushes, and signs the image by digest |
| `cosign.pub` | Public key for verifying signed image pushes |
