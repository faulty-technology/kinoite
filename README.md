# kinoite

Custom [bootc](https://github.com/bootc-dev/bootc) images based on [Fedora Kinoite](https://fedoraproject.org/kinoite/) 44, built using [ublue-os/image-template](https://github.com/ublue-os/image-template).

This repo builds **two images** from one shared codebase:

| Image                                     | Target machine                                          | Role               |
| ----------------------------------------- | ------------------------------------------------------- | ------------------ |
| `ghcr.io/faulty-technology/kinoite`       | laptop                                                  | dev / daily driver |
| `ghcr.io/faulty-technology/kinoite-north` | AMD 9900X + dual Radeon AI PRO R9700 (Fractal North XL) | gaming + local LLM |

Both share the same baseline (1Password, Chrome, Tailscale, Nix, font fixes, signed bootc auto-updates); `kinoite-north` layers on AMD/RDNA4 enablement, a lean gaming core, and Sunshine streaming. Both are rebuilt automatically on push via GitHub Actions.

Documentation lives in [`docs/`](docs/). Start at [`docs/overview.md`](docs/overview.md) — what is where, and what is still open. The three on-box runbooks (`docs/how-to/{vllm,lemonade,llamafactory}.md`) are installed to `/usr/share/kinoite/` so they are readable on the machine with no repo checked out. [`AGENTS.md`](AGENTS.md) records which documents may be rewritten and which are append-only.

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

- **AMD / RDNA4 (R9700, gfx1201):** `amd-gpu-firmware`, `mesa-vulkan-drivers`, `amdsmi`, and a udev rule tagging `/dev/kfd` for `uaccess` (with `render`-group fallback) so containerized ROCm can reach the compute node. **No host ROCm** — lemonade's llama.cpp builds bundle their own ROCm 7 runtime, so it tracks independently of Fedora 44. (Fedora may already ship `/dev/kfd` world-accessible the way it does the DRM render nodes, which would make that rule redundant — unverified, see `docs/overview.md`.)
- **Three local-LLM stacks, all baked but *not enabled*.** Each is a rootless Podman Quadlet under `/etc/containers/systemd/users/`, started by hand, published on **loopback only** (the APIs are unauthenticated), and sharing one HuggingFace store at `~/.local/share/models/huggingface` — so a model pulled by any stack is reused by all, and an adapter trained here is immediately loadable for inference. None has an `[Install]` section and none is referenced by `services-north.sh`, so none can be enabled by accident (`systemctl --user enable` on a generator-produced unit fails by design — that's the guardrail, not a bug). In practice **only one can hold the GPUs at a time**. Rationale for every design decision lives in the matching `build_files/profiles/north/*.sh`; the runbooks below ship on the box for when it breaks and there's no repo checked out.

  | Stack | What it does | Start | UI | On-box runbook |
  |---|---|---|---|---|
  | `lemonade` | llama.cpp GGUF inference | `systemctl --user start lemonade` | `127.0.0.1:13305` | `/usr/share/kinoite/lemonade.md` |
  | `vllm` | batched tensor-parallel inference | `systemctl --user start north-llm-pod` | `127.0.0.1:8000`, Open WebUI `:3000` | `/usr/share/kinoite/vllm.md` |
  | `llamafactory` | the only one that ***trains*** | `systemctl --user start llamafactory` | LLaMA Board `127.0.0.1:7860`, Jupyter `:8889` | `/usr/share/kinoite/llamafactory.md` |

  First start is slow for two of them and this is expected, not a hang: `lemonade` **pulls** a multi-GB image (15 min), and `llamafactory` **builds** one against AMD's gfx1201 wheels (90 min) because no prebuilt image for this arch exists. Watch `journalctl --user -u <unit> -f`.

- **Sleep/wake for the LLM stacks:** `kinoite-llm-sleep.service` stops whichever stack is running before the box suspends and starts back exactly what was up (expect 1-2 min before the model answers again). **A correctness fix, not a power tweak:** suspending with a model loaded hangs the machine hard enough to need the power button, with nothing in the kernel log. It restores state rather than enforcing policy — a stack you stopped by hand stays stopped, and waking the box to stream a game leaves both dGPUs free. Working in daily use: VRAM drains and rehydrates across cycles, and a suspended box is **silent**, because nothing is left holding the cards awake. Resume restores the *server*, not an in-flight training run, so hold the box awake with `systemd-inhibit` for a long fine-tune. Opt out with `systemctl disable`, never `mask`. Why it is mandatory: [`docs/explanation/suspend-and-wake.md`](docs/explanation/suspend-and-wake.md).
- **Gaming (lean core):** `steam`, `gamescope`, `gamemode`, `mangohud`, `protontricks`, `umu-launcher`, plus `mesa-va-drivers-freeworld.i686` so 32-bit Proton titles get the same VA-API stack as the 64-bit side. Everything else (emulators, Lutris, Heroic, ...) is added as-needed via Flatpak/distrobox. **Proton-GE is baked in** at `/usr/share/steam/compatibilitytools.d/`, pinned by sha512 to a specific release so a rebase reproduces the exact Proton a title was verified against — it appears in Steam's compatibility dropdown with no setup. Steam merges that with `~/.steam/root/compatibilitytools.d/`, so ProtonUp-Qt still works for pulling newer builds between rebuilds. Note this adds ~1.3 GB to the image. `umu-launcher` comes from Bazzite's COPR (the only maintained RPM source) restricted via `includepkgs` so it can't pull that repo's patched mesa/kernel/gamescope over ours. `split_lock_detect=off` is baked as a kernel arg — the kernel's split-lock throttling costs some Proton titles an order of magnitude of frame rate.
- **Streaming:** `sunshine` (via the `pvermeer/sunshine` COPR, key fingerprint-pinned — a Fedora-Atomic-targeted build with spec fixes LizardByte's own COPR lacks) enabled as a user service, plus `krfb` + `kscreen` for a KDE Wayland virtual monitor sized to the client (the Apollo-equivalent). The virtual monitor is **on demand**: Sunshine's `global_prep_cmd` runs `/usr/libexec/sunshine-virtual-display ensure` to create it at the client's resolution and refresh rate when a stream starts, and `... down` to drop it when the stream ends — `krfb-virtualmonitor` holds a DRM render node while it runs, which would otherwise keep a GPU awake around the clock. A persistent variant (`sunshine-virtual-monitor.service`) ships **disabled**, for genuinely headless boxes where losing the virtual output would put KWin at zero outputs: `systemctl --user enable --now sunshine-virtual-monitor.service`. **This does not make the box headless** — the virtual monitor rides on top of an existing session, so a real output (dummy plug, or a connector forced on via karg) is still required; pulling the plug breaks streaming entirely. Sunshine's default `kms` capture can't see a virtual monitor and silently streams the physical panel instead, so the service seeds `capture = kwin` and `output_name = Virtual-sunshine-vm` into the per-user config on start (UI changes win).
- **AMD tunings:** `vm.max_map_count=2147483642` sysctl (Proton games + LLM mmap), the `amdgpu.ppfeaturemask=0xfff7ffff` kernel arg (driver default plus `PP_OVERDRIVE_MASK`, which unlocks clock/voltage offsets — narrower than the `0xffffffff` most guides repeat), and `kinoite-gpu-tune.service`, a oneshot that applies a **235 W power cap** to each R9700 at boot. It's plain sysfs writes — no daemon. Override the values in `/etc/kinoite/gpu-tune.conf` (documented example at `/usr/share/kinoite/gpu-tune.conf.example`), inspect with `sudo /usr/libexec/kinoite-gpu-tune status`. **Durability is not uniform, and it drives the whole design:** `power1_cap` survives a runtime suspend/resume, but the voltage offset and fan curve live in the OverDrive table, which amdgpu drops on *every* D3→D0 transition — roughly ten seconds after the cards go idle. So the cap is set-and-forget and the other two are shipped unset, knobs present and documented. Fan curves *are* possible now (`gpu_od/fan_ctrl/fan_curve`, five points, and the earlier "R9700 fan control is dead" was the missing karg rather than the vBIOS), but 30% is a hard firmware floor — 30% of the 6500 RPM max is the ~1950 RPM "floor", so a curve can only make an awake card louder. `lact` is installed but its daemon ships **disabled**: it's the GUI for tuning experiments, and it reverts the power cap the moment it stops. Don't reach for `amd-smi` — it has no voltage-offset argument at all and *dumps core* on gfx1201. See `docs/explanation/gpu-power-and-fans.md` and `docs/reference/gpu-sysfs.md`.
- **Motherboard (ASUS ProArt B850-Creator WiFi Neo):** `acpi_enforce_resources=lax` kernel arg + auto-loaded `nct6775` so `lm_sensors`/fan tools see the Nuvoton NCT6701D fan RPM + voltages. Wi-Fi 7 (RTL8922AE), dual 5GbE (RTL8126), and audio work in-kernel — no baking needed. CoolerControl was removed 2026-08-18: it couldn't drive this board's fans (NCT6701D too new) and its 1s GPU-hwmon polling kept both R9700s permanently awake at ~30% fan — see `docs/explanation/gpu-power-and-fans.md`.

> **First-login setup for `kinoite-north`:**
>
> Almost nothing. GPU access, container passthrough, linger and suspend/resume all
> work out of the box. Three things need a human:
>
> 1. **Check the powerplay karg.** `kargs.d` does not reliably deliver it and the
>    failure is invisible — OverDrive stays locked and LACT's voltage offset is
>    silently dropped. `grep -o 'amdgpu.ppfeaturemask=\S*' /proc/cmdline`; if empty,
>    `sudo rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff` and reboot.
>    The 235 W cap applies either way; only the offset and fan curve need OverDrive.
>    Why: [`docs/explanation/gpu-power-and-fans.md`](docs/explanation/gpu-power-and-fans.md).
> 2. **Pair a Sunshine client** at `https://127.0.0.1:47990`. That is the only
>    manual step for streaming — [`docs/how-to/stream-with-sunshine.md`](docs/how-to/stream-with-sunshine.md).
> 3. **`hf auth login`**, before any model pull. `HF_HOME` already points at the
>    shared store, so the token lands inside it and every LLM container picks it up
>    with no per-container secret plumbing. (Anything mounting the store can read
>    it — single-user box, deliberate trade.)
>
> The LLM stacks ship installed and stopped, none with an `[Install]` section, and
> only one can hold the GPUs at a time:
>
>     systemctl --user start lemonade         # :13305   llama.cpp, the decode path
>     systemctl --user start north-llm-pod    # :3000    vLLM + Open WebUI
>     systemctl --user start llamafactory     # :7860    fine-tuning
>
> Each ships a runbook on the box at `/usr/share/kinoite/{lemonade,vllm,llamafactory}.md`
> — first-run behaviour, troubleshooting and tuning live there, not here. Start with
> [`docs/overview.md`](docs/overview.md) for what is where.
>
> Gaming: Proton-GE is already in Steam's **Properties → Compatibility** dropdown.
> `protontricks <appid> --gui` for per-prefix fixes, `umu-run` for Windows games
> outside Steam. **3DMark** needs hardware monitoring turned off in its settings or
> it hangs at startup; it then stalls again once the benchmark runs, unresolved.

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
| `AGENTS.md`                      | Where each kind of document lives and what may be done to it (`CLAUDE.md` points here) |
| `docs/`                          | All prose. `overview.md` first; `how-to/{vllm,lemonade,llamafactory}.md` ship to `/usr/share/kinoite/` |
| `scripts/`                       | Repo tooling, never shipped (`new-run.sh` scaffolds a run record)    |
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
