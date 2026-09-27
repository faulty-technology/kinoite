#!/usr/bin/env bash
# Repo tooling (never ships): builds a drop-in replacement RPM for Fedora's libfprint.
# Invoked by .github/workflows/build.yml (fedora:44 container) and usable standalone
# on any F44 host. Content: upstream 1.94.x base + Depau/armiaab elanmoc2 match-on-chip driver
# + added 04f3:0c99 id-table entry, built WITHOUT the 'elan' and 'elanmoc'
# drivers so 0c99 can only bind to elanmoc2 (first-match-wins selection in
# fp-context.c would otherwise let stock elanmoc shadow it).
#
# Run as root on the box (Fedora 44). On rpm-ostree hosts /usr is immutable,
# so build deps cannot be dnf-installed — the build then runs in a disposable
# fedora:44 container (requires podman). Context:
# docs/runs/2026-09-27-fingerprint-elan-0c99-identity.md
set -euo pipefail

SRC_COMMIT=81ba47e   # armiaab/libfprint tip; carries fix 78b0cff (timeout/suspend/UAF/assertion/heap fixes)
DEPS="gcc-c++ make meson rpm-build pkgconf-pkg-config git tar glib2-devel libgusb-devel systemd-devel bzip2-devel zlib-devel openssl-devel cairo-devel pixman-devel binutils"

# --- toolchain gate: ostree hosts build in a throwaway container ---
if [ "${1:-}" != "--in-container" ]; then
  if ! (command -v meson >/dev/null && command -v gcc >/dev/null && command -v rpmbuild >/dev/null); then
    if command -v rpm-ostree >/dev/null; then
      command -v podman >/dev/null || { echo "ERROR: immutable /usr (rpm-ostree) and no podman. Install podman, or build on a mutable workstation and copy the RPM over."; exit 1; }
      SCRIPT=$(readlink -f "$0")
      OUTDIR=$(mktemp -d /tmp/fprint-moc2-out.XXXXXX)
      echo "==> immutable /usr detected: building in a disposable fedora:44 container"
      exec podman run --rm -v "$(dirname "$SCRIPT")":/host:z -v "$OUTDIR":/out \
        quay.io/fedora/fedora:44 \
        bash -c "dnf install -y ${DEPS} && HOST_OSTREE=1 HOST_OUTDIR='$OUTDIR' bash /host/$(basename "$SCRIPT") --in-container"
    fi
    echo "==> install build deps"
    dnf install -y ${DEPS}
  fi
fi

WORK=$(mktemp -d /tmp/fprint-moc2-build.XXXXXX)
trap 'echo "workdir kept at $WORK"' EXIT

echo "==> fetch source @ ${SRC_COMMIT}"
git clone https://github.com/armiaab/libfprint.git "$WORK/src"
git -C "$WORK/src" checkout -q "$SRC_COMMIT"

echo "==> add 0x0c99 to the elanmoc2 id table"
python3 - "$WORK/src/libfprint/drivers/elanmoc2/elanmoc2.c" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c90, .driver_data = ELANMOC2_ALL_DEV},'
assert anchor in s, 'anchor line not found - table layout changed, aborting'
assert '0x0c99' not in s, '0x0c99 already present - check before re-running'
s = s.replace(anchor, anchor + '\n  {.vid = ELANMOC2_VEND_ID, .pid = 0x0c99, .driver_data = ELANMOC2_ALL_DEV},')
open(p, 'w').write(s)
PY
grep -n '0x0c99' "$WORK/src/libfprint/drivers/elanmoc2/elanmoc2.c"

echo "==> rpmbuild tree + spec"
mkdir -p ~/rpmbuild/SOURCES ~/rpmbuild/BUILD ~/rpmbuild/RPMS
tar czf ~/rpmbuild/SOURCES/libfprint-moc2.tar.gz -C "$WORK" src
cat > "$WORK/spec" <<'SPEC'
Name:           libfprint
Version:        1.94.100
Release:        99.moc2.fc44
Summary:        Drop-in libfprint + elanmoc2 driver (04f3:0c99); elan/elanmoc excluded
License:        MIT
Source0:        libfprint-moc2.tar.gz
BuildRequires:  gcc-c++, make, meson, pkgconf-pkg-config
BuildRequires:  glib2-devel, libgusb-devel, systemd-devel, bzip2-devel, zlib-devel
BuildRequires:  openssl-devel, cairo-devel, pixman-devel

%description
Upstream libfprint 1.94.x (fork tip tracks ~1.94.9) plus the Depau elanmoc2
match-on-chip driver with an added 04f3:0c99 id-table entry. Built without
the 'elan' and 'elanmoc' drivers so 0c99 binds exclusively to elanmoc2.
Test package for the kinoite fingerprint fix phase; displaces the stock
libfprint (same Name, higher Release).

%prep
%setup -q -n src

%build
# F44's systemd-devel ships only libudev.pc; meson looks up the name 'udev'.
ln -sf /usr/lib64/pkgconfig/libudev.pc /usr/lib64/pkgconfig/udev.pc
DRIVERS="upektc_img,vfs5011,vfs7552,aes3500,aes4000,aes1610,aes1660,aes2660,aes2501,aes2550,vfs101,vfs301,vfs0050,etes603,egis0570,egismoc,vcom5s,synaptics,elanmoc2,uru4000,upektc,upeksonly,upekts,goodixmoc,nb1010,fpcmoc,realtek,focaltech_moc"
meson setup builddir -Dprefix=/usr -Ddrivers="$DRIVERS" -Dintrospection=false -Dgtk-examples=false -Ddoc=false -Dinstalled-tests=false
meson compile -C builddir

%install
DESTDIR=%{buildroot} meson install -C builddir
( cd %{buildroot} && find . \( -type f -o -type l \) | sed 's|^\./|/|' | sort ) > /tmp/libfprint-moc2.filelist

%files -f /tmp/libfprint-moc2.filelist
SPEC
rpmbuild -ba --define "_topdir $HOME/rpmbuild" "$WORK/spec"
RPM=$(ls ~/rpmbuild/RPMS/*/libfprint-*.rpm | head -1)
if [ -d /out ]; then install -m 644 "$RPM" /out/; fi

echo "==> verify built .so driver registration"
SO=$(find ~/rpmbuild/BUILD -name 'libfprint-2.so*' | head -1)
test -n "$SO"
test "$(strings "$SO" | grep -c 'ELAN Match-on-Chip 2')" -ge 1
test "$(strings "$SO" | grep -c 'Elan MOC Sensors')" -eq 0
test "$(strings "$SO" | grep -c 'ElanTech Fingerprint Sensor')" -eq 0
echo "OK: elanmoc2 present; elan + elanmoc absent"

echo
echo "BUILD OK: $RPM"
if [ "${HOST_OSTREE:-0}" = "1" ] || command -v rpm-ostree >/dev/null; then
  RPMREF="$RPM"
  if [ -n "${HOST_OUTDIR:-}" ]; then RPMREF="${HOST_OUTDIR}/$(basename "$RPM")"; fi
  echo "This is an rpm-ostree system — layer the RPM and REBOOT before testing:"
  echo "  sudo rpm-ostree install '$RPMREF' && sudo reboot"
  echo "  # AFTER reboot: sudo systemctl restart fprintd && sleep 30 && fprintd-list"
  echo "Rollback: sudo rpm-ostree revert && sudo reboot  (removes ALL layered pkgs — check 'rpm-ostree status' first)"
else
  echo "Next: dnf install '$RPM' && sudo systemctl restart fprintd && sleep 30 && fprintd-list"
fi
