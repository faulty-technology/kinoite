# kinoite

Custom [bootc](https://github.com/bootc-dev/bootc) images based on [Fedora Kinoite](https://fedoraproject.org/kinoite/) 44, built using [ublue-os/image-template](https://github.com/ublue-os/image-template).

This repo builds **two images** from one shared codebase:

| Image                                     | Target machine                                          | Role               |
| ----------------------------------------- | ------------------------------------------------------- | ------------------ |
| `ghcr.io/faulty-technology/kinoite`       | laptop                                                  | dev / daily driver |
| `ghcr.io/faulty-technology/kinoite-north` | AMD 9900X + dual Radeon AI PRO R9700 (Fractal North XL) | gaming + local LLM |

Both share the same baseline (1Password, Chrome, Tailscale, Nix, font fixes, signed bootc auto-updates); `kinoite-north` layers on AMD/RDNA4 enablement, a lean gaming core, and Sunshine streaming. Both are rebuilt automatically on push via GitHub Actions.

## What's included

### Shared baseline (both images)

**Packages**

- `1password` — password manager (via official 1Password repo)
- `distrobox` — container-based development environments
- `google-chrome-stable` — browser (via Google repo)
- `lm_sensors` — hardware monitoring
- `podman-compose` — Docker Compose-compatible tooling
- `tailscale` — VPN mesh network (via Tailscale repo)
- `rpmfusion-free-release` / `rpmfusion-nonfree-release` — RPM Fusion repos
- `ffmpeg` / `mesa-va-drivers-freeworld` / `gstreamer1-plugins-bad-freeworld` — full multimedia codecs from RPM Fusion, swapped in over Fedora's patent-stripped builds. Restores H.264/HEVC playback and, critically, VAAPI **hardware encode** (absent on stock Fedora, which is why Sunshine reports "no h264").
- `nix` / `nix-daemon` — [Nix](https://nixos.org/) in multi-user mode (modern CLI + flakes; no legacy `nix-*` commands). User packages are managed declaratively via a separate home-manager flake; the store persists in `/var/nix`, bind-mounted onto `/nix` at boot.

**Enabled services**

- `tailscaled`
- `podman.socket`
- `nix-daemon.socket` (+ `var-nix.service` / `nix.mount` for the persistent `/nix` store)

**Other changes**

- `/opt` is made immutable (unlinked from `/var/opt`) so packages like Google Chrome persist correctly across deploys.
- Font mtimes are normalized to epoch and system fontconfig caches rebuilt at image build time, so caches validate on the deployed (mtime-0) ostree filesystem instead of going stale per-user.

Third-party repo files are removed after install — updates come from CI image rebuilds rather than live `dnf` updates.

### Laptop image (`kinoite`) extras

- `intel-media-driver` — Intel hardware video acceleration
- `powertop` — laptop power tuning

### Battlestation image (`kinoite-north`) extras

- **AMD / RDNA4 (R9700, gfx1201):** `amd-gpu-firmware`, `mesa-vulkan-drivers`, `amdsmi`, and a udev rule tagging `/dev/kfd` for `uaccess` (with `render`-group fallback) so containerized ROCm can reach the compute node. **No host ROCm** — ROCm 7.2+ (required for gfx1201) runs in containers so it tracks independently of Fedora 44.
- **Gaming (lean core):** `steam`, `gamescope`, `gamemode`, `mangohud`, plus `mesa-va-drivers-freeworld.i686` so 32-bit Proton titles get the same VA-API stack as the 64-bit side. Everything else (emulators, Lutris, ...) is added as-needed via Flatpak/distrobox.
- **Streaming:** `sunshine` (via the `pvermeer/sunshine` COPR, key fingerprint-pinned — a Fedora-Atomic-targeted build with spec fixes LizardByte's own COPR lacks) enabled as a user service, plus `krfb` + `kscreen` for a KDE Wayland virtual monitor — a no-dummy-plug virtual display (the Apollo-equivalent). Helper: `/usr/libexec/sunshine-virtual-display`.
- **AMD tunings:** `vm.max_map_count=2147483642` sysctl (Proton games + LLM mmap), the `amdgpu.ppfeaturemask=0xffffffff` kernel arg baked via bootc `kargs.d` (unlocks power/clock/fan controls), and `lact` (LACT — power caps, fan curves, monitoring) with its `lactd` daemon enabled.
- **Motherboard (ASUS ProArt B850-Creator WiFi Neo):** `acpi_enforce_resources=lax` kernel arg + auto-loaded `nct6775` so `lm_sensors`/fan tools see the Nuvoton NCT6701D fan RPM + voltages, plus `coolercontrol` / `coolercontrold` (system/CPU/case fan curves) with the daemon enabled. Wi-Fi 7 (RTL8922AE), dual 5GbE (RTL8126), and audio work in-kernel — no baking needed.

> **First-login setup for `kinoite-north`:**
>
> - GPU access should need no setup: systemd ACLs the render nodes to the active seat user, and the shipped `70-kfd.rules` extends the same `uaccess` treatment to `/dev/kfd`. If a container can't reach `/dev/kfd` — or you're driving the box headless over SSH, where there's no active seat to grant an ACL — fall back to `sudo usermod -aG render,video $USER` and re-login.
> - Sunshine: complete pairing, and set **Configuration → Advanced → Force Capture Method → kwin** (the default `kms` capture can't see the krfb virtual monitor). Wire `/usr/libexec/sunshine-virtual-display up|down` into Sunshine's Command Preparation to bring the virtual display up per-connection.
> - Confirm the powerplay karg applied: `cat /proc/cmdline | grep ppfeaturemask`. If the first `rpm-ostree rebase` didn't pick it up from `kargs.d`, apply once: `sudo rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xffffffff` (image updates keep it afterward). Then open LACT to set power/fan.

## Rebasing to an image

From a stock Fedora Kinoite system (swap `kinoite` for `kinoite-north` for the battlestation):

```bash
# First rebase (unverified, to bootstrap)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/faulty-technology/kinoite:latest

# After reboot, switch to the signed image
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/faulty-technology/kinoite:latest
```

Once on the image, you can also use `bootc switch` for future switches:

```bash
bootc switch ghcr.io/faulty-technology/kinoite:latest
```

## Building

Images are built, signed, and pushed by GitHub Actions on every push to `main` (a matrix over both images). For a one-off local build:

```bash
podman build -t kinoite -f Containerfile .
podman build -t kinoite-north -f Containerfile.north .
```

## Repository layout

| Path                             | Description                                                          |
| -------------------------------- | -------------------------------------------------------------------- |
| `Containerfile`                  | Laptop image; runs `build_files/profiles/base/build.sh`              |
| `Containerfile.north`            | Battlestation image; runs `build_files/profiles/north/build.sh`      |
| `build_files/scripts/`           | Shared, image-agnostic scripts (repos, Nix, fonts, signing, cleanup) |
| `build_files/scripts/signing.sh` | Signature policy, parameterized by `IMAGE_NAME` per image            |
| `build_files/profiles/base/`     | Laptop-specific package set                                          |
| `build_files/profiles/north/`    | AMD/RDNA4, gaming, Sunshine, and LLM-enablement scripts              |
| `.github/workflows/build.yml`    | CI: matrix-builds, pushes, and signs both images by digest           |
| `cosign.pub`                     | Public key for verifying signed image pushes (shared by both images) |
