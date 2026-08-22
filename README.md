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

- **AMD / RDNA4 (R9700, gfx1201):** `amd-gpu-firmware`, `mesa-vulkan-drivers`, `amdsmi`, and a udev rule tagging `/dev/kfd` for `uaccess` (with `render`-group fallback) so containerized ROCm can reach the compute node. **No host ROCm** — lemonade's llama.cpp builds bundle their own ROCm 7 runtime, so it tracks independently of Fedora 44. (Fedora may already ship `/dev/kfd` world-accessible the way it does the DRM render nodes, which would make that rule redundant — unverified, see `notes/kinoite-north-validation.md`.)
- **Local LLM (`lemonade`):** a baked but **not enabled** rootless Podman Quadlet at `/etc/containers/systemd/users/lemonade.container`, running `ghcr.io/lemonade-sdk/lemonade-server`. Start it by hand — `systemctl --user start lemonade`. It has no `[Install]` section and nothing in `services-north.sh`, so it can't be enabled by accident (`systemctl --user enable` on a generator-produced unit fails by design). API + web UI on `127.0.0.1:13305` only; the API is unauthenticated. `/dev/kfd` and `/dev/dri` are passed through, and `UserNS=keep-id:uid=10001` maps the container's user onto your login UID so the three bind mounts under `~/.local/share/lemonade/` (models, llama.cpp+ROCm binaries, config) stay yours to inspect, prune and back up — named volumes and `:U` recursive chowns were both rejected for that. The image seeds `llamacpp.backend=rocm`, `rocm_channel=nightly` (the only channel with gfx1201 support — `stable` silently runs on CPU) and `ctx_size=131072`. ROCm needs one thing the container doesn't get by default: `container-selinux` denies `map` on `/dev/kfd`, which ROCm mmaps, and the resulting HSA abort looks nothing like a permission error — so `lemonade-selinux.service` flips `container_use_devices` at boot, guarded and idempotent. That keeps the container fully confined; disabling SELinux labelling or sharing host IPC "fix" it too, but both simply turn off the confinement. Measured on a 27B Q5_K_M: ~35 tok/s on ROCm, ~29 on Vulkan (`llamacpp.backend=vulkan` any time). On-box notes and troubleshooting: `/usr/share/kinoite/lemonade.md`.
- **Sleep/wake for the LLM stacks:** `kinoite-llm-sleep.service` stops whichever local LLM stack is running before the box suspends and starts back exactly what was running on resume (expect 1-2 min before the model answers again). A correctness fix, not a power tweak: amdgpu evicts VRAM into system RAM to suspend, a loaded vLLM holds ~28 GiB on **each** R9700, and 64 GB of system RAM cannot take it — **suspending with a model loaded hangs the machine** and needs the power button, with nothing in the kernel log. It restores state rather than enforcing policy, so a stack you stopped by hand stays stopped and waking the box to stream a game leaves both dGPUs free. One hook covers suspend, hibernate and hybrid-sleep. It must be a *system* unit reaching into the user manager (the user manager has no sleep target of its own), which makes it depend on `kinoite-linger.service` for the user bus. Opt out with `systemctl disable`, never `mask`. On-box notes: `/usr/share/kinoite/vllm.md`.
- **Gaming (lean core):** `steam`, `gamescope`, `gamemode`, `mangohud`, `protontricks`, `umu-launcher`, plus `mesa-va-drivers-freeworld.i686` so 32-bit Proton titles get the same VA-API stack as the 64-bit side. Everything else (emulators, Lutris, Heroic, ...) is added as-needed via Flatpak/distrobox. **Proton-GE is baked in** at `/usr/share/steam/compatibilitytools.d/`, pinned by sha512 to a specific release so a rebase reproduces the exact Proton a title was verified against — it appears in Steam's compatibility dropdown with no setup. Steam merges that with `~/.steam/root/compatibilitytools.d/`, so ProtonUp-Qt still works for pulling newer builds between rebuilds. Note this adds ~1.3 GB to the image. `umu-launcher` comes from Bazzite's COPR (the only maintained RPM source) restricted via `includepkgs` so it can't pull that repo's patched mesa/kernel/gamescope over ours. `split_lock_detect=off` is baked as a kernel arg — the kernel's split-lock throttling costs some Proton titles an order of magnitude of frame rate.
- **Streaming:** `sunshine` (via the `pvermeer/sunshine` COPR, key fingerprint-pinned — a Fedora-Atomic-targeted build with spec fixes LizardByte's own COPR lacks) enabled as a user service, plus `krfb` + `kscreen` for a KDE Wayland virtual monitor sized to the client (the Apollo-equivalent). The virtual monitor is **on demand**: Sunshine's `global_prep_cmd` runs `/usr/libexec/sunshine-virtual-display ensure` to create it at the client's resolution and refresh rate when a stream starts, and `... down` to drop it when the stream ends — `krfb-virtualmonitor` holds a DRM render node while it runs, which would otherwise keep a GPU awake around the clock. A persistent variant (`sunshine-virtual-monitor.service`) ships **disabled**, for genuinely headless boxes where losing the virtual output would put KWin at zero outputs: `systemctl --user enable --now sunshine-virtual-monitor.service`. **This does not make the box headless** — the virtual monitor rides on top of an existing session, so a real output (dummy plug, or a connector forced on via karg) is still required; pulling the plug breaks streaming entirely. Sunshine's default `kms` capture can't see a virtual monitor and silently streams the physical panel instead, so the service seeds `capture = kwin` and `output_name = Virtual-sunshine-vm` into the per-user config on start (UI changes win).
- **AMD tunings:** `vm.max_map_count=2147483642` sysctl (Proton games + LLM mmap), the `amdgpu.ppfeaturemask=0xfff7ffff` kernel arg baked via bootc `kargs.d` (driver default plus `PP_OVERDRIVE_MASK`, which unlocks clock/voltage offsets — narrower than the `0xffffffff` most guides repeat), and `lact` (LACT — power caps, monitoring) with its `lactd` daemon enabled. R9700 fan control needs a current GPU vBIOS — before flashing, every tool got EINVAL. Note `lactd` polls GPU hwmon once a second, which keeps the dGPUs from ever reaching runtime-suspend; `systemctl stop lactd` reclaims that idle and already-applied settings persist. See `notes/kinoite-north-validation.md`.
- **Motherboard (ASUS ProArt B850-Creator WiFi Neo):** `acpi_enforce_resources=lax` kernel arg + auto-loaded `nct6775` so `lm_sensors`/fan tools see the Nuvoton NCT6701D fan RPM + voltages. Wi-Fi 7 (RTL8922AE), dual 5GbE (RTL8126), and audio work in-kernel — no baking needed. CoolerControl was removed 2026-08-18: it couldn't drive this board's fans (NCT6701D too new) and its 1s GPU-hwmon polling kept both R9700s permanently awake at ~30% fan — see `notes/kinoite-north-validation.md`.

> **First-login setup for `kinoite-north`:**
>
> - GPU access should need no setup: systemd ACLs the render nodes to the active seat user, and the shipped `70-kfd.rules` extends the same `uaccess` treatment to `/dev/kfd`. If a container can't reach `/dev/kfd` — or you're driving the box headless over SSH, where there's no active seat to grant an ACL — fall back to `sudo usermod -aG render,video $USER` and re-login.
> - Lemonade is installed but not running: `systemctl --user start lemonade`, then `http://127.0.0.1:13305` (first start pulls a multi-GB image; the unit allows 15 minutes). GPU passthrough needs no setup — no group changes, no SELinux booleans, and it survives logout: `kinoite-linger.service` asserts `loginctl enable-linger` for every regular account at boot (linger lives in `/var`, which is machine-local rather than part of the image, so it has to be re-asserted rather than baked). It starts nothing on its own — neither Quadlet has an `[Install]` section — it only keeps a hand-started server alive. If a model load dies instantly with `Memory critical error … Reason: Memory in use` and exit 134, that's SELinux denying `map` on `/dev/kfd` — check `systemctl status lemonade-selinux.service` before anything else, since nothing about the error points at permissions. Suspend needs no setup either — `kinoite-llm-sleep.service` parks whatever is running before the box sleeps and brings it back on wake. Full detail in `/usr/share/kinoite/lemonade.md`.
> - Sunshine: **pairing is the only manual step.** Capture method (`kwin`), output name (`Virtual-sunshine-vm`), and the virtual-display prep command are seeded into `~/.config/sunshine/sunshine.conf` on service start — existing settings are never overwritten, so if a stream arrives at the wrong aspect ratio, check those three under **Configuration → Advanced / General**. The virtual display is persistent from login and made primary so new windows open on the streamed monitor. Existing windows stay on the physical output; to pull them onto the virtual display (and stream with the panels off), change the Do command to `/usr/libexec/sunshine-virtual-display ensure --exclusive`, globally or for a single app entry; disabling the physical outputs is what makes KWin migrate their windows. Undo is seeded as `/usr/libexec/sunshine-virtual-display ensure` — it restores physical outputs when the stream ends (Do without `--exclusive` runs the same logic). ExecStopPost does the same as a backup if Sunshine stops while a stream is still active. If you already have a config with `global_prep_cmd` pointing to `sunshine-virtual-display up` (pre-persistent design), edit `~/.config/sunshine/sunshine.conf` and set both `do` and `undo` to `/usr/libexec/sunshine-virtual-display ensure`; otherwise every stream will teardown and recreate the display instead of resizing it.
> - Gaming: Proton-GE is already in Steam's **Properties → Compatibility** dropdown — nothing to install. `protontricks <appid> --gui` for per-prefix fixes, `umu-run` for Windows games outside Steam. Note **3DMark** hangs at startup collecting system info — disable hardware monitoring in its settings (SystemInfo is genuinely Wine-incompatible). It has a second, unresolved stall once the benchmark starts; see `notes/kinoite-north-validation.md`.
> - Confirm the powerplay karg applied: `cat /proc/cmdline | grep ppfeaturemask`. If the first `rpm-ostree rebase` didn't pick it up from `kargs.d`, apply once: `sudo rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff` (image updates keep it afterward). Then open LACT to set power and clock offsets.

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
| `build_files/scripts/`           | Shared, image-agnostic scripts (repos, codecs, Nix, fonts, signing, cleanup) |
| `build_files/scripts/lib/`       | Sourced helpers: `install_pkgs` (install + SBOM manifest in one call), `add_copr` (pin key, write repo, register cleanup), `check-keys.sh` |
| `build_files/scripts/signing.sh` | Signature policy, parameterized by `IMAGE_NAME` per image            |
| `build_files/profiles/base/`     | Laptop-specific package set                                          |
| `build_files/profiles/north/`    | AMD/RDNA4, gaming, Sunshine, and LLM-enablement scripts              |
| `.github/workflows/build.yml`    | CI: matrix-builds, pushes, and signs both images by digest           |
| `cosign.pub`                     | Public key for verifying signed image pushes (shared by both images) |
