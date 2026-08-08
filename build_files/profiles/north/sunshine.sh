#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/verify-key.sh"

# Sunshine game-streaming host + KDE Wayland virtual display (the Apollo-equivalent
# "no dummy plug" setup). Sunshine is distributed for Fedora via the LizardByte
# COPR. We use the *beta* COPR because LizardByte stable releases are not aligned
# with Fedora releases and often lag a new Fedora version (stable is frequently
# missing for the newest Fedora — beta is the recommended path).
#
# TODO(hardware): validate krfb-virtualmonitor drives a client-scaled virtual
# monitor into Sunshine on RDNA4/Wayland, and confirm the beta COPR has an fc44
# build (re-verify the pinned key via lib/check-keys.sh if the build fails on a
# GPG mismatch). See notes/kinoite-north-validation.md.

### Add the LizardByte beta COPR (repo written inline; key fingerprint-pinned)
verify_and_import_key "lizardbyte-beta" "LizardByte (Sunshine COPR)" \
    "https://download.copr.fedorainfracloud.org/results/lizardbyte/beta/pubkey.gpg" \
    8DBE8112F49BA56B18688093BD3BF808010833A1

cat > /etc/yum.repos.d/_copr_lizardbyte-beta.repo << 'EOF'
[copr:copr.fedorainfracloud.org:lizardbyte:beta]
name=Copr repo for beta owned by lizardbyte
baseurl=https://download.copr.fedorainfracloud.org/results/lizardbyte/beta/fedora-$releasever-$basearch/
type=rpm-md
skip_if_unavailable=False
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-lizardbyte-beta
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF

### Install Sunshine + the KDE virtual-monitor tooling
# krfb provides krfb-virtualmonitor; kscreen (kscreen-doctor) tweaks the virtual
# output's refresh/resolution after it is created.
PACKAGES=(
    Sunshine
    krfb
    kscreen
)
dnf5 install -y "${PACKAGES[@]}"
printf '%s\n' "${PACKAGES[@]}" >> /usr/share/kinoite/packages

### Virtual-display helper
# Sunshine's default kms capture cannot see a krfb virtual monitor — capture must
# be forced to "kwin" (Sunshine Web UI → Configuration → Advanced → Force Capture
# Method → kwin). That is per-user app config, so it is a documented first-login
# step rather than baked. This helper spins up a right-sized virtual monitor and
# is intended to be wired into Sunshine's "Command Preparations" (do/undo) so a
# client connection brings the display up and tears it down on disconnect.
cat > /usr/libexec/sunshine-virtual-display << 'EOF'
#!/bin/bash
# Bring up a KDE Wayland virtual monitor for Sunshine streaming (no dummy plug).
# Usage: sunshine-virtual-display up|down [WIDTH HEIGHT]
# Wire into Sunshine: Configuration → General → Command Preparation
#   Do:   /usr/libexec/sunshine-virtual-display up   ${SUNSHINE_CLIENT_WIDTH} ${SUNSHINE_CLIENT_HEIGHT}
#   Undo: /usr/libexec/sunshine-virtual-display down
set -euo pipefail
VM_NAME="sunshine-vm"
# Per-user runtime dir, not /tmp: a fixed name in a world-writable directory is
# a predictable path we later feed straight to kill(1), and XDG_RUNTIME_DIR is
# also immune to the two invocations disagreeing about PrivateTmp.
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/${VM_NAME}.pid"
case "${1:-}" in
    up)
        W="${2:-2560}"; H="${3:-1440}"
        # --password/--port are required by krfb-virtualmonitor even though the
        # VNC side goes unused here (Sunshine captures via kwin, not VNC).
        krfb-virtualmonitor --name "$VM_NAME" --resolution "${W}x${H}" \
            --password sunshine --port 5905 &
        echo $! > "$PIDFILE"
        ;;
    down)
        if [ -s "$PIDFILE" ]; then
            pid=$(cat "$PIDFILE")
            # Only signal it if it's still the virtual monitor — PIDs get recycled.
            case "$(cat "/proc/$pid/comm" 2>/dev/null || true)" in
                krfb-virtualmo*) kill "$pid" 2>/dev/null || true ;;
            esac
        fi
        rm -f "$PIDFILE"
        ;;
    *)
        echo "usage: $0 up|down [WIDTH HEIGHT]" >&2; exit 2 ;;
esac
EOF
chmod +x /usr/libexec/sunshine-virtual-display
