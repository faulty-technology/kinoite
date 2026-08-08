# kinoite-north — hardware validation checklist

Open items that can only be confirmed on the real machine (AMD 9900X, dual Radeon
AI PRO R9700 / RDNA4 / gfx1201). The `kinoite-north` image builds and ships today,
but these should be verified before treating it as production. Code that depends on
one of these carries a `TODO(hardware):` comment pointing here.

## 1. R9700 (RDNA4) driver currency — `build_files/profiles/north/amdgpu.sh`
- [ ] Boots to KDE Wayland with working display on the R9700.
- [ ] `amdgpu` module loaded; both GPUs enumerate (`lspci`, `/sys/class/drm`).
- [ ] Vulkan works: `vulkaninfo` / `glxinfo` report the RDNA4 GPU(s).
- Fallback if Fedora 44's kernel/linux-firmware/mesa are too old: a newer-kernel
  COPR, or a `linux-firmware` override for the gfx1201 microcode.

## 2. Virtual display, no dummy plug — `build_files/profiles/north/sunshine.sh`
- [ ] `krfb-virtualmonitor` creates a virtual output on RDNA4/Wayland.
- [ ] Sunshine capture set to **kwin** (default `kms` can't see the virtual monitor).
- [ ] A Moonlight/Artemis client connects and the display scales to the client
      resolution (the Apollo-equivalent behavior).
- [ ] `/usr/libexec/sunshine-virtual-display up|down` wired into Sunshine's
      Command Preparation brings the display up per-connection and tears it down.

## 3. Sunshine service + firewall — `build_files/profiles/north/services-north.sh`
- [ ] `systemctl --user status app-dev.lizardbyte.app.Sunshine.service` is running
      after first login (enabled `--global`, `WantedBy=graphical-session.target`).
      Note the unit's real filename — `sunshine.service` is only an `Alias=`, which
      exists solely as a symlink created by enabling the real name.
- [ ] Ports reachable: the RPM ships **no** firewalld service file, so unless the
      only clients are on Tailscale these need opening —
      `sudo firewall-cmd --permanent --add-port=47984-47990/tcp \
       --add-port=48010/tcp --add-port=47998-48000/udp --add-port=48002/udp \
       --add-port=48010/udp && sudo firewall-cmd --reload`
- [ ] The LizardByte **beta** COPR has a `fedora-44` build of `Sunshine`
      (stable frequently lags a new Fedora release; that's why we use beta).
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
- [ ] Rootless podman passes through `/dev/kfd` + `/dev/dri` (login user in
      `render,video`; see the `70-kfd.rules` udev rule in `amdgpu.sh`).
- [ ] lemonade runs against the R9700 in a container.
- [ ] Codify the working setup as a Quadlet `.container` unit baked into the image
      and enabled from `services-north.sh` (replaces the current no-op in `llm.sh`).
