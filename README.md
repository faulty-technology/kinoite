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
- **No S3 / deep sleep.** Firmware reports `ACPI: PM: (supports S0 S4 S5)` and `/sys/power/mem_sleep`
  offers only `s2idle`. A `mem_sleep_default=deep` karg does not buy deep sleep here — it selects a
  mode the kernel never made available, so every suspend logs a failed `PM: suspend entry (deep)`
  and falls back to s2idle. Removed 2026-08-24; don't re-add it.

### Battlestation image (`kinoite-north`) extras

- **AMD / RDNA4 (R9700, gfx1201):** `amd-gpu-firmware`, `mesa-vulkan-drivers`, `amdsmi`, and a udev rule tagging `/dev/kfd` for `uaccess` (with `render`-group fallback) so containerized ROCm can reach the compute node. **No host ROCm** — lemonade's llama.cpp builds bundle their own ROCm 7 runtime, so it tracks independently of Fedora 44. (Fedora may already ship `/dev/kfd` world-accessible the way it does the DRM render nodes, which would make that rule redundant — unverified, see `notes/kinoite-north-validation.md`.)
- **Local LLM (`lemonade`):** a baked but **not enabled** rootless Podman Quadlet at `/etc/containers/systemd/users/lemonade.container`, running `ghcr.io/lemonade-sdk/lemonade-server`. Start it by hand — `systemctl --user start lemonade`. It has no `[Install]` section and nothing in `services-north.sh`, so it can't be enabled by accident (`systemctl --user enable` on a generator-produced unit fails by design). API + web UI on `127.0.0.1:13305` only; the API is unauthenticated. `/dev/kfd` and `/dev/dri` are passed through, and `UserNS=keep-id:uid=10001` maps the container's user onto your login UID so the three bind mounts under `~/.local/share/lemonade/` (models, llama.cpp+ROCm binaries, config) stay yours to inspect, prune and back up — named volumes and `:U` recursive chowns were both rejected for that. The image seeds `llamacpp.backend=rocm`, `rocm_channel=nightly` (the only channel with gfx1201 support — `stable` silently runs on CPU) and `ctx_size=131072`. ROCm needs one thing the container doesn't get by default: `container-selinux` denies `map` on `/dev/kfd`, which ROCm mmaps, and the resulting HSA abort looks nothing like a permission error — so `lemonade-selinux.service` flips `container_use_devices` at boot, guarded and idempotent. That keeps the container fully confined; disabling SELinux labelling or sharing host IPC "fix" it too, but both simply turn off the confinement. Measured on a 27B Q5_K_M: ~35 tok/s on ROCm, ~29 on Vulkan (`llamacpp.backend=vulkan` any time). On-box notes and troubleshooting: `/usr/share/kinoite/lemonade.md`.
- **Fine-tuning (`unsloth`):** a baked but **not enabled** rootless Quadlet at `/etc/containers/systemd/users/unsloth.container` — the third LLM stack, and the only one that *trains*. Start it by hand: `systemctl --user start unsloth`. Jupyter Lab on `127.0.0.1:8889`, loopback only. `UNSLOTH_UI=studio|jupyter|both` picks the UI and **defaults to `jupyter`** — Unsloth Studio (no-code training UI, `127.0.0.1:8888`) is *not* runnable from a plain `pip install unsloth[studio]`: its frontend isn't shipped as package data and its CLI gates on an installer-managed venv that only `unsloth.ai/install.sh` builds — and *every* `unsloth studio` subcommand sits behind that same gate, `update` included, so the CLI cannot install itself. Studio is therefore an opt-in `podman exec -it unsloth sh -c 'curl -fsSL https://unsloth.ai/install.sh | UNSLOTH_SKIP_AUTOSTART=1 sh'` away, and the launcher falls back to Jupyter instead of crash-looping if you ask for one you haven't installed. That installer builds a **second, self-contained stack** in the venv — its own Node, Vite build, prebuilt llama.cpp and its own torch, several GB, all on the persistent studio volume — so Studio trains on `repo.amd.com/rocm/whl/gfx120X-all` torch 2.11.x while the image runs 2.12.0+rocm7.14.0. Neither can disturb the other; they are simply not the same stack. `UNSLOTH_ROCM_GFX_ARCH=gfx1201` is set on the unit because that installer's GPU probes are `rocminfo`, `amd-smi`, `lspci` and Strix names in `/proc/cpuinfo` — all of which come up empty in this container, whereupon it silently installs **CPU-only** torch. **The image is built on the box, not pulled** — there is no Unsloth image for gfx1201 anywhere (`unsloth/unsloth` is CUDA-only and the community ROCm rebuilds publish only gfx942 and gfx1100), so a guarded `ExecStartPre` runs `podman build` against the baked recipe at `/usr/share/kinoite/unsloth/Containerfile` on first start. That recipe follows AMD's documented pip path: `torch[device-gfx1201]==2.12.0+rocm7.14.0` and friends from `repo.amd.com/rocm/whl-multi-arch/`, *then* `unsloth[amd,studio]` — ordering matters, because unsloth's `amd` extra is deliberately torch-less and keeps whatever torch it finds. Like lemonade's, these wheels bundle their own ROCm, so the host still has none. It mounts the **shared** HuggingFace store, so a base model pulled by any stack is reused by all and an adapter exported to GGUF here is immediately loadable by lemonade. Unlike `vllm.container` it runs **without** `--ipc=host` or `--group-add` — both measured unnecessary (devices are 0666) and the former silently drops SELinux label separation — so `--shm-size=16g` covers the dataloader and multi-GPU RCCL training is consequently untested. The launcher pins `HIP_VISIBLE_DEVICES` to the gfx1201 cards at every start, derived from `gcnArchName` rather than baked, and warns if another stack is already holding VRAM. On-box notes: `/usr/share/kinoite/unsloth.md`.
- **Sleep/wake for the LLM stacks:** `kinoite-llm-sleep.service` stops whichever local LLM stack is running before the box suspends and starts back exactly what was running on resume (expect 1-2 min before the model answers again). A correctness fix, not a power tweak: amdgpu evicts VRAM into system RAM to suspend, a loaded vLLM holds ~28 GiB on **each** R9700, and 64 GB of system RAM cannot take it — **suspending with a model loaded hangs the machine** and needs the power button, with nothing in the kernel log. A fine-tuning run is the same hazard from the other direction, so `unsloth.service` is on the list too — note that resume restores the *server*, not an in-flight training run, so hold the box awake with `systemd-inhibit` for a long fine-tune. It restores state rather than enforcing policy, so a stack you stopped by hand stays stopped and waking the box to stream a game leaves both dGPUs free. One hook covers suspend, hibernate and hybrid-sleep. It must be a *system* unit reaching into the user manager (the user manager has no sleep target of its own), which makes it depend on `kinoite-linger.service` for the user bus. Opt out with `systemctl disable`, never `mask`. On-box notes: `/usr/share/kinoite/vllm.md`.
- **Gaming (lean core):** `steam`, `gamescope`, `gamemode`, `mangohud`, `protontricks`, `umu-launcher`, plus `mesa-va-drivers-freeworld.i686` so 32-bit Proton titles get the same VA-API stack as the 64-bit side. Everything else (emulators, Lutris, Heroic, ...) is added as-needed via Flatpak/distrobox. **Proton-GE is baked in** at `/usr/share/steam/compatibilitytools.d/`, pinned by sha512 to a specific release so a rebase reproduces the exact Proton a title was verified against — it appears in Steam's compatibility dropdown with no setup. Steam merges that with `~/.steam/root/compatibilitytools.d/`, so ProtonUp-Qt still works for pulling newer builds between rebuilds. Note this adds ~1.3 GB to the image. `umu-launcher` comes from Bazzite's COPR (the only maintained RPM source) restricted via `includepkgs` so it can't pull that repo's patched mesa/kernel/gamescope over ours. `split_lock_detect=off` is baked as a kernel arg — the kernel's split-lock throttling costs some Proton titles an order of magnitude of frame rate.
- **Streaming:** `sunshine` (via the `pvermeer/sunshine` COPR, key fingerprint-pinned — a Fedora-Atomic-targeted build with spec fixes LizardByte's own COPR lacks) enabled as a user service, plus `krfb` + `kscreen` for a KDE Wayland virtual monitor sized to the client (the Apollo-equivalent). The virtual monitor is **on demand**: Sunshine's `global_prep_cmd` runs `/usr/libexec/sunshine-virtual-display ensure` to create it at the client's resolution and refresh rate when a stream starts, and `... down` to drop it when the stream ends — `krfb-virtualmonitor` holds a DRM render node while it runs, which would otherwise keep a GPU awake around the clock. A persistent variant (`sunshine-virtual-monitor.service`) ships **disabled**, for genuinely headless boxes where losing the virtual output would put KWin at zero outputs: `systemctl --user enable --now sunshine-virtual-monitor.service`. **This does not make the box headless** — the virtual monitor rides on top of an existing session, so a real output (dummy plug, or a connector forced on via karg) is still required; pulling the plug breaks streaming entirely. Sunshine's default `kms` capture can't see a virtual monitor and silently streams the physical panel instead, so the service seeds `capture = kwin` and `output_name = Virtual-sunshine-vm` into the per-user config on start (UI changes win).
- **AMD tunings:** `vm.max_map_count=2147483642` sysctl (Proton games + LLM mmap), the `amdgpu.ppfeaturemask=0xfff7ffff` kernel arg (driver default plus `PP_OVERDRIVE_MASK`, which unlocks clock/voltage offsets — narrower than the `0xffffffff` most guides repeat), and `kinoite-gpu-tune.service`, a oneshot that applies a **235 W power cap** to each R9700 at boot. It's plain sysfs writes — no daemon. Override the values in `/etc/kinoite/gpu-tune.conf` (documented example at `/usr/share/kinoite/gpu-tune.conf.example`), inspect with `sudo /usr/libexec/kinoite-gpu-tune status`. **Durability is not uniform, and it drives the whole design:** `power1_cap` survives a runtime suspend/resume, but the voltage offset and fan curve live in the OverDrive table, which amdgpu drops on *every* D3→D0 transition — roughly ten seconds after the cards go idle. So the cap is set-and-forget and the other two are shipped unset, knobs present and documented. Fan curves *are* possible now (`gpu_od/fan_ctrl/fan_curve`, five points, and the earlier "R9700 fan control is dead" was the missing karg rather than the vBIOS), but 30% is a hard firmware floor — 30% of the 6500 RPM max is the ~1950 RPM "floor", so a curve can only make an awake card louder. `lact` is installed but its daemon ships **disabled**: it's the GUI for tuning experiments, and it reverts the power cap the moment it stops. Don't reach for `amd-smi` — it has no voltage-offset argument at all and *dumps core* on gfx1201. See `notes/kinoite-north-validation.md`.
- **Motherboard (ASUS ProArt B850-Creator WiFi Neo):** `acpi_enforce_resources=lax` kernel arg + auto-loaded `nct6775` so `lm_sensors`/fan tools see the Nuvoton NCT6701D fan RPM + voltages. Wi-Fi 7 (RTL8922AE), dual 5GbE (RTL8126), and audio work in-kernel — no baking needed. CoolerControl was removed 2026-08-18: it couldn't drive this board's fans (NCT6701D too new) and its 1s GPU-hwmon polling kept both R9700s permanently awake at ~30% fan — see `notes/kinoite-north-validation.md`.

> **First-login setup for `kinoite-north`:**
>
> - GPU access needs no setup, on the desktop or headless over SSH: `/dev/kfd` and the DRM render nodes are mode **0666** straight from systemd-udev's base rules, so containers reach the compute node with no group changes and no active seat required. (Earlier builds shipped a `70-kfd.rules` that tightened `/dev/kfd` to 0660 and handed access back via `uaccess`/`render`; it was removed because the base rules are already more permissive — see `amdgpu.sh`.)
> - Lemonade is installed but not running: `systemctl --user start lemonade`, then `http://127.0.0.1:13305` (first start pulls a multi-GB image; the unit allows 15 minutes). GPU passthrough needs no setup — no group changes, no SELinux booleans, and it survives logout: `kinoite-linger.service` asserts `loginctl enable-linger` for every regular account at boot (linger lives in `/var`, which is machine-local rather than part of the image, so it has to be re-asserted rather than baked). It starts nothing on its own — neither Quadlet has an `[Install]` section — it only keeps a hand-started server alive. If a model load dies instantly with `Memory critical error … Reason: Memory in use` and exit 134, that's SELinux denying `map` on `/dev/kfd` — check `systemctl status lemonade-selinux.service` before anything else, since nothing about the error points at permissions. Suspend needs no setup either — `kinoite-llm-sleep.service` parks whatever is running before the box sleeps and brings it back on wake. Full detail in `/usr/share/kinoite/lemonade.md`.
> - **Fine-tuning:** `hf auth login` first — `python3-huggingface-hub` puts `/usr/bin/hf` on the host, and `/etc/profile.d/kinoite-hf.sh` points `HF_HOME` at the shared model store, so the token lands *inside* that store and every LLM container picks it up with no per-container secret plumbing. (The flip side: anything mounting the store can read it. Single-user box, deliberate trade.) Then stop the other stacks — `systemctl --user stop north-llm-pod lemonade` — because vLLM alone idles at ~24 GiB per card and a fine-tune needs room for gradients and optimiser state on top. `systemctl --user start unsloth`; **the first start builds a multi-GB image and the unit allows 90 minutes**, so a long silent stretch is expected, not a hang — watch `journalctl --user -u unsloth -f`, which is also where Studio and Jupyter print their first-run credentials. Rebuild deliberately with `podman build --no-cache`; it never rebuilds on a restart. Full detail in `/usr/share/kinoite/unsloth.md`.
> - Sunshine: **pairing is the only manual step.** Capture method (`kwin`), output name (`Virtual-sunshine-vm`), and the virtual-display prep command are seeded into `~/.config/sunshine/sunshine.conf` on service start — existing settings are never overwritten, so if a stream arrives at the wrong aspect ratio, check those three under **Configuration → Advanced / General**. The virtual display is persistent from login and made primary so new windows open on the streamed monitor. Existing windows stay on the physical output; to pull them onto the virtual display (and stream with the panels off), change the Do command to `/usr/libexec/sunshine-virtual-display ensure --exclusive`, globally or for a single app entry; disabling the physical outputs is what makes KWin migrate their windows. Undo is seeded as `/usr/libexec/sunshine-virtual-display ensure` — it restores physical outputs when the stream ends (Do without `--exclusive` runs the same logic). ExecStopPost does the same as a backup if Sunshine stops while a stream is still active. If you already have a config with `global_prep_cmd` pointing to `sunshine-virtual-display up` (pre-persistent design), edit `~/.config/sunshine/sunshine.conf` and set both `do` and `undo` to `/usr/libexec/sunshine-virtual-display ensure`; otherwise every stream will teardown and recreate the display instead of resizing it.
> - Gaming: Proton-GE is already in Steam's **Properties → Compatibility** dropdown — nothing to install. `protontricks <appid> --gui` for per-prefix fixes, `umu-run` for Windows games outside Steam. Note **3DMark** hangs at startup collecting system info — disable hardware monitoring in its settings (SystemInfo is genuinely Wine-incompatible). It has a second, unresolved stall once the benchmark starts; see `notes/kinoite-north-validation.md`.
> - **Apply the powerplay karg by hand — `kargs.d` does not reliably deliver it.** `/usr/lib/bootc/kargs.d` is a bootc mechanism: `bootc install`/`switch`/`upgrade` read it, `rpm-ostree rebase`/`upgrade` ignores it. That alone does not explain what happens here — north updates with `bootc upgrade` (`bootc-fetch-apply-updates.timer` active and enabled since 2026-03-04, `rpm-ostreed-automatic.timer` masked) and all three entries were added months later, yet measured 2026-08-24 only `30-gaming` had landed: `20-sensors` was missing from the booted *and* staged deployments, and `10-amdgpu` was present only because it had been applied by hand. Why remains unexplained, so treat `kargs.d` as best-effort and check `/proc/cmdline` rather than trusting it. The failure is invisible — OverDrive stays locked, `pp_od_clk_voltage` and `gpu_od/` don't exist, and LACT's voltage offset is dropped with only an ERROR line in its journal. Check with `grep -o 'amdgpu.ppfeaturemask=\S*' /proc/cmdline`; if it's empty, `sudo rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff` and reboot. That writes it into the ostree deployment, where it persists across updates whichever tool drives them. `kinoite-gpu-tune.service` asserts this at every boot and says so in its journal, so it cannot go quiet again. The 235 W power cap applies with or without it; only the voltage offset and fan curve need OverDrive. For interactive experiments, `sudo systemctl start lactd` and open LACT — the daemon ships disabled on purpose.

## Rebasing to an image

From a stock Fedora Kinoite system (swap `kinoite` for `kinoite-north` for the battlestation):

```bash
# First rebase (unverified, to bootstrap)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/faulty-technology/kinoite:latest

# After reboot, switch to the signed image
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/faulty-technology/kinoite:latest
```

Once on the image you can also use `bootc switch` for future switches — but **pass
`--enforce-container-sigpolicy`**. Without it `bootc switch` sets the deployment origin to
`ostree-unverified-registry:` and every subsequent update is pulled with no signature check at
all. Nothing warns you; the origin line in `rpm-ostree status` is the only place it shows. This
is how `kinoite-north` ended up unverified, caught 2026-08-24.

```bash
bootc switch --enforce-container-sigpolicy ghcr.io/faulty-technology/kinoite:latest
```

Verify afterwards — the origin must read `ostree-image-signed:docker://…` and not
`ostree-unverified-registry:…`:

```bash
rpm-ostree status | grep -E 'ostree-(image-signed|unverified)'
```

**Don't rely on `kargs.d` for a kernel argument you actually need.** Only `bootc` reads
`/usr/lib/bootc/kargs.d`, so an `rpm-ostree`-updated box never receives the kargs baked there — and
even on a bootc-updated box, entries have been measured not to land; see the powerplay karg note
above for what was observed on north. Kernel arguments set with `rpm-ostree kargs` live in the
ostree deployment and survive updates from either tool, which makes that the dependable place to
put one. Keep the `kargs.d` files regardless — they are still what makes a fresh `bootc install`
come up correct.

**btrfs compression lives in `rootflags=`, not `/etc/fstab`.** Under composefs the fstab options for
`/` are ignored, and btrfs mount options are per-filesystem rather than per-subvolume — the first
mount wins. The initramfs mounts the filesystem as `/sysroot` using `rootflags=`, so `/`, `/home` and
`/var` all inherit whatever that karg says and the `compress=zstd:1` sitting in fstab does nothing.
Set it once per machine:

```bash
sudo rpm-ostree kargs --delete-if-present=rootflags=subvol=root \
                      --append=rootflags=subvol=root,compress=zstd:1
```

Verify with `grep -c compress=zstd:1 /proc/mounts` — every btrfs line should carry it. Only new
writes are compressed; existing data needs `btrfs filesystem defragment -r -czstd`, which unshares
reflinks and can raise usage where snapshots share extents.

This is deliberately *not* baked into `kargs.d`. That mechanism is additive and `rootflags` already
exists from installation, so an entry there would duplicate the argument rather than amend it — like
`root=`, it is install-time machine state, not image state.

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
| `build_files/scripts/lib/`       | Sourced helpers: `install_pkgs` (install + SBOM manifest in one call), `add_copr` (pin key, write repo, register cleanup), `check-keys.sh` (verifies vendored + live keys against pins), `update-keys.sh` (re-vendors keys after rotation) |
| `build_files/keys/`              | Vendored vendor GPG keys (fingerprint-pinned in the calling scripts); the build imports these locally instead of fetching from vendor URLs |
| `build_files/scripts/signing.sh` | Signature policy, parameterized by `IMAGE_NAME` per image            |
| `build_files/profiles/base/`     | Laptop-specific package set                                          |
| `build_files/profiles/north/`    | AMD/RDNA4, gaming, Sunshine, and LLM-enablement scripts              |
| `.github/workflows/build.yml`    | CI: matrix-builds, pushes, and signs both images by digest           |
| `cosign.pub`                     | Public key for verifying signed image pushes (shared by both images) |
