# kinoite-north — hardware validation checklist

Open items that can only be confirmed on the real machine (AMD 9900X, dual Radeon
AI PRO R9700 / RDNA4 / gfx1201). The `kinoite-north` image builds and ships today,
but these should be verified before treating it as production. Code that depends on
one of these carries a `TODO(hardware):` comment pointing here.

## 1. R9700 (RDNA4) driver currency — `build_files/profiles/north/amdgpu.sh`

> **Largely answered 2026-08-08** by a Sunshine log on the real box: mesa 26.1.6
> radeonsi drives the R9700 as `gfx1201` (ACO, DRM 3.64) on kernel
> 7.1.7-200.fc44. No newer-kernel COPR or firmware override needed. Sunshine
> enumerated three amdgpu nodes (card0/1/2) and used card0/card2 for KMS.

- [ ] Boots to KDE Wayland with working display on the R9700.
- [ ] `amdgpu` module loaded; both GPUs enumerate (`amd-smi list`, `lspci`).
- [ ] `amd-smi monitor` reports temp/power/VRAM for both cards. Fedora ships
      amdsmi 7.1.1, so confirm it recognizes gfx1201 rather than erroring — if
      it doesn't, the ROCm container's own amd-smi is the fallback.
- [ ] Vulkan works: `vulkaninfo` / `glxinfo` report the RDNA4 GPU(s).
- [ ] `vainfo` lists **VAEntrypointEncSlice** for H264 — this is what Sunshine
      needs, and stock Fedora mesa doesn't have it (hence the freeworld swaps in
      `codecs.sh`). If Sunshine reports no h264 encoder, check here first.
- [ ] The codec installs resolved at build time — verify in the CI log, this was
      never test-built. `mesa-va-drivers-freeworld.i686` in `gaming.sh` assumes
      steam pulled the i686 mesa stack in first.
- [ ] HDR, if wanted: `mesa-vulkan-drivers-freeworld` supersedes `VK_hdr_layer`,
      but RPM Fusion trails Fedora's mesa (26.0.3 vs 26.1.6) so we don't swap it
      — a Vulkan downgrade on RDNA4 is the worse trade. Revisit if RPM Fusion
      catches up and gamescope HDR turns out to matter.
- [ ] **Encoder picks the right GPU.** The box enumerates *three* amdgpu nodes
      (card0/1/2 — dual R9700 plus the 9900X iGPU). If Sunshine encodes on the
      iGPU, pin it with `adapter_name` in sunshine.conf to the discrete card's
      render node. Check which is which via `amd-smi list`.
- Fallback if Fedora 44's kernel/linux-firmware/mesa are too old: a newer-kernel
  COPR, or a `linux-firmware` override for the gfx1201 microcode.

## 2. Virtual display, no dummy plug — `build_files/profiles/north/sunshine.sh`

- [x] `krfb-virtualmonitor` creates a virtual output on RDNA4/Wayland — confirmed
      2026-08-08: `Virtual-sunshine-vm` appears at 2560x1440, and the
      `sunshine-virtual-display up` prep command fires correctly.
- [ ] Sunshine capture set to **kwin**. Still outstanding, and the log shows the
      exact failure it causes: KMS enumeration logs
      `Unknown Monitor connector type [Virtual-sunshine]`, discards the virtual
      output, and falls back to `Mapped 'HDMI-A-2' to kmsgrab monitor index 0` —
      i.e. it streams the physical panel, not the virtual one.
- [ ] A Moonlight/Artemis client connects and the display scales to the client
      resolution (the Apollo-equivalent behavior).
- [ ] `/usr/libexec/sunshine-virtual-display up|down` wired into Sunshine's
      Command Preparation brings the display up per-connection and tears it down.

## 3. Sunshine service — `build_files/profiles/north/services-north.sh`

- [ ] `systemctl --user status app-dev.lizardbyte.app.Sunshine.service` is running
      after first login (enabled `--global`, `WantedBy=graphical-session.target`).
      Note the unit's real filename — `sunshine.service` is only an `Alias=`, which
      exists solely as a symlink created by enabling the real name.
- [ ] A client connects. Sunshine's ports (47984-47990, 47998-48010) fall inside
      the 1025-65535 range the FedoraWorkstation zone leaves open, so no firewall
      work is expected — Sunshine on Bazzite needed none. Only chase this if a
      client actually fails to reach the host.
- [ ] Clipboard is **KDE Connect's job, not Sunshine's** — pair the two machines
      (works over Tailscale if they're not on the same LAN). Sunshine has no
      clipboard sync in any build or channel: upstream closed host→client on
      security grounds (#1539) and the text-only proposal as `not_planned`
      (#5384). Don't debug Sunshine for this.
- [ ] If the build fails on a GPG mismatch, re-verify every pinned fingerprint with
      `build_files/scripts/lib/check-keys.sh` (it diffs the pins against the live
      vendor keys and exits nonzero on drift).

## 4. Motherboard sensors — `build_files/profiles/north/motherboard.sh`

ASUS ProArt B850-Creator WiFi Neo, Nuvoton NCT6701D Super I/O.

- [ ] `sensors` shows `nct6775`/`nct6799` fan RPM + voltages (needs the
      `acpi_enforce_resources=lax` karg to be active — check `/proc/cmdline`).
- [ ] CoolerControl (`coolercontrold` running) sees the mobo/CPU/case fans and can
      set curves.
- [ ] Temps: expect some NCT6701D channels to read 0C/missing on Fedora 44 — recheck
      as `asus-ec-sensors` gains an entry for this board on newer kernels.
- [ ] Verify (no bake needed): Wi-Fi 7 `rtw89_8922ae` associates, dual 5GbE
      `r8169`/RTL8126 links up, audio works.

## 5. Containerized ROCm + lemonade — `build_files/profiles/north/llm.sh`

- [ ] Pick a gfx1201-capable ROCm **7.2+** container image (Fedora 44's host ROCm
      is too old — this is why ROCm stays containerized).
- [ ] `TAG+="uaccess"` actually lands on `/dev/kfd` — it's a non-DRM device, so
      whether logind assigns it to a seat is the open question. Check with
      `getfacl /dev/kfd` while logged in locally: the login user should appear
      in the ACL without being in `render`. If it does not, the
      `usermod -aG render,video` fallback becomes mandatory again (and it stays
      mandatory for headless/SSH use either way — no active seat, no ACL).
- [ ] Rootless podman passes through `/dev/kfd` + `/dev/dri`
      (see the `70-kfd.rules` udev rule in `amdgpu.sh`).
- [ ] lemonade runs against the R9700 in a container.
- [ ] Codify the working setup as a Quadlet `.container` unit baked into the image
      and enabled from `services-north.sh` (replaces the current no-op in `llm.sh`).
