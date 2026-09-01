#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### Remove unwanted base image packages
dnf5 remove -y firefox firefox-langpacks

### Install standard Fedora packages
# Same core as the laptop image MINUS laptop-only bits (intel-media-driver,
# powertop). distrobox + podman-compose double as the containerized-LLM
# enablers (ROCm/lemonade run in containers — see lemonade.sh).
#
# python3-huggingface-hub is the HOST-side Hugging Face CLI (/usr/bin/hf, plus
# huggingface-cli and tiny-agents). It exists so pulling a base model is `hf download`
# rather than a Python snippet inside whichever container happens to be running, and so
# `hf auth login` can write one token that all three LLM stacks pick up — see the
# HF_HOME profile.d snippet in llamafactory.sh for how that reaches them.
install_pkgs \
    distrobox \
    lm_sensors \
    podman-compose \
    python3-huggingface-hub

### hf_xet — Xet-backed transfers for the host `hf` CLI
# Hugging Face serves most repos over Xet now. Without this package huggingface_hub logs
# "Xet Storage is enabled for this repo, but the 'hf_xet' package is not installed" on every
# pull and falls back to plain HTTP, which is the slow path for the multi-GB GGUF and
# safetensors files this box exists to download.
#
# Fedora has no RPM for it (checked F44 and rawhide), so it comes from PyPI as a pinned,
# checksummed wheel — same shape as the Proton-GE fetch in gaming.sh. Bump version, wheel
# name, URL and hash together. It is a self-contained Rust extension with no runtime deps,
# and the wheel is cp38-abi3, so it keeps working across a Python minor bump.
#
# Unzipped rather than pip-installed, straight into the interpreter's /usr platlib. Mind the
# scheme name: on Fedora 44 `posix_prefix` is the /usr/local scheme (platbase /usr/local) and
# `rpm_prefix` is the /usr one — the opposite of the older posix_local naming. Aiming at
# /usr/local is doubly wrong here: it is a symlink to ../var/usrlocal, which is per-machine
# state bootc never updates, is absent from sys.path, and does not even exist in the build
# container (the extraction dies with FileNotFoundError on /usr/local/lib64). Overriding
# base/platbase to /usr pins the answer to /usr/lib64/python3.X/site-packages — on the default
# sys.path and part of the image — without betting on which scheme name Fedora ships.
#
# Deliberately NOT passed to record_pkgs: bake_sbom runs `rpm -q` over the manifest and this
# is not an RPM, so declaring it would fail the build.
HF_XET_VERSION="1.6.0"
HF_XET_WHEEL="hf_xet-${HF_XET_VERSION}-cp38-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.whl"
HF_XET_SHA256="d62671bb130879cef0ee4c9ebe47a14af6c66ec53e6d84dc15936e5ffdfac82f"

curl -fsSL --retry 6 --retry-delay 5 --retry-all-errors --connect-timeout 15 --max-time 300 \
    -o "/tmp/${HF_XET_WHEEL}" \
    "https://files.pythonhosted.org/packages/67/4e/a28359bf1c1ecf11eba22123168c138698f7cb576ac678f5a2e16cd5da08/${HF_XET_WHEEL}"

echo "${HF_XET_SHA256}  /tmp/${HF_XET_WHEEL}" | sha256sum -c -

HF_XET_SITE="$(python3 -c 'import sysconfig; print(sysconfig.get_path("platlib", "posix_prefix", vars={"base": "/usr", "platbase": "/usr"}))')"
python3 -m zipfile -e "/tmp/${HF_XET_WHEEL}" "$HF_XET_SITE"
rm -f "/tmp/${HF_XET_WHEEL}"

# zipfile extraction doesn't carry modes across; the .so and its metadata have to stay
# readable by the unprivileged user actually running `hf`.
chmod -R a+rX "${HF_XET_SITE}/hf_xet" "${HF_XET_SITE}/hf_xet-${HF_XET_VERSION}.dist-info"

# Assert it loads AND is discoverable. huggingface_hub's is_xet_available() goes through
# importlib.metadata, not a bare import, so the .dist-info matters as much as the .so — and a
# wheel that unpacked but didn't resolve would only ever show up as a silent HTTP fallback.
# HF_HOME keeps hf_xet's Rust logger, which opens a log under $HF_HOME/xet/logs the moment the
# extension loads, from writing into /root and printing ERROR lines into the build log.
HF_XET_VERSION="$HF_XET_VERSION" HF_HOME="$(mktemp -d)" python3 - << 'PYEOF'
import os
import hf_xet  # noqa: F401  — the Rust extension actually loads
from importlib.metadata import version

want = os.environ["HF_XET_VERSION"]
got = version("hf_xet")
assert got == want, f"packages.sh: hf_xet resolves to {got}, expected {want}"
PYEOF
