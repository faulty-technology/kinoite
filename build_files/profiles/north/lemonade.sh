#!/bin/bash
set -ouex pipefail

# Lemonade Server (local LLM) as a rootless Quadlet. No host ROCm — lemonade's
# llama.cpp builds bundle their own ROCm 7 runtime.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by
# hand with `systemctl --user start lemonade`. Runbook and gotchas are in
# /usr/share/kinoite/lemonade.md (source: docs/how-to/lemonade.md).
#
# crun is still required: podman needs an OCI runtime and crun is what this image ships.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "lemonade.sh: missing $bin" >&2; exit 1; }
done

### 1. Seeded lemonade defaults
# nightly channel pinned because stable/preview have no gfx1201 support — a silent ~7x
# CPU fallback. lemonade-sdk/lemonade#1787. ctx_size: lemonade auto-tunes to 157140 on
# a 27B; override to 131072. `--load-mode mmap` removed after SELinux bisect (ROCm loads
# fine without it). Full details: docs/runs/2026-09-05-build-comment-consolidation.md#nightly-channel-pin
mkdir -p /usr/share/kinoite
cat > /usr/share/kinoite/lemonade-defaults.json << 'EOF'
{
  "ctx_size": 131072,
  "rocm_channel": "nightly",
  "llamacpp": {
    "backend": "rocm"
  }
}
EOF

### 1b. Curated custom-model recipes (always-present superset)
# Baked to /usr/share/kinoite/lemonade-recipes and merged into the user's lemonade config
# on every start, per key (see kinoite-lemonade-seed and the ExecStartPre in the Quadlet).
# Names become user.<name> at runtime — run one with `lemonade run user.<name>`.
#
# Recipes: Q6_K quality floor with MTP on every model that has it (unsloth ships MTP
# in two packagings — separate draft file vs. embedded in the main GGUF — needing
# different recipe shapes). IQ4_XS Fast is the speed exception, benchmarked but not
# quality-tested. Qwen3-Coder-30B is the only model without MTP.
# Throughput figures: docs/runs/2026-08-20-mtp-speculation.md.
# Quant rationale: docs/explanation/quant-selection.md.
# Full MTP packaging and ctx sizing detail: docs/runs/2026-09-05-build-comment-consolidation.md#why-q6-floor-why-mtp-why-two-packaging-shapes

command -v python3 >/dev/null || { echo "lemonade.sh: missing python3 (JSON validation)" >&2; exit 1; }

mkdir -p /usr/share/kinoite/lemonade-recipes
cat > /usr/share/kinoite/lemonade-recipes/user_models.json << 'EOF'
{
  "Qwen3.8-27B": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q6_K.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 23.4,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.8-27B-Fast": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-IQ4_XS.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 15.6,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp", "fast"]
  },
  "Qwen3.8-27B-Q6XL": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q6_K_XL.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 25.3,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.8-27B-Q8XL": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q8_K_XL.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 31.5,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.6-27B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 22.9,
    "labels": ["custom", "vision", "reasoning", "mtp"]
  },
  "Qwen3.6-35B-A3B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 30.0,
    "labels": ["custom", "vision", "reasoning", "mtp"]
  },
  "Qwen3-Coder-30B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf",
    "recipe": "llamacpp",
    "size": 25.1,
    "labels": ["custom", "coding"]
  }
}
EOF

# Per-model ctx and llamacpp_args, keyed by the fully-qualified user.<name> id.
# backend inherits rocm from defaults.json.
#
# `-sm tensor -fa on` baked on the four Qwen3.8-27B recipes only.
# ON: +44.4% over layer split, composes with MTP, leads vLLM at every depth.
# OFF on Qwen3.6-27B, Qwen3.6-35B-A3B, Qwen3-Coder-30B: `-sm tensor` has an architecture
# gate whose failure mode is a hard load failure; none has been loaded here.
# Four constraints: `-fa on` mandatory, iGPU excluded at visibility (not per-flag),
# ctx hand-computed (0.0444 MiB/token/card + 12174 MiB/card; `--fit` disabled),
# `--chat-template-kwargs` carries both keys in one JSON object.
# Full rationale and tensor-split constraints: docs/runs/2026-09-05-build-comment-consolidation.md#-sm-tensor-split-across-recipes
# Measured: docs/runs/2026-08-30-tensor-split.md, docs/runs/2026-08-30-quant-sweep.md.
#
# Passthrough is the only route: the lemonade binary contains no `--split-mode` / `-devd` /
# `--spec-draft-device` / `-ngld` strings. Recipe `llamacpp_args` is appended last and merges
# per flag.
#
# REASONING EFFORT pinned to MEDIUM on the four Qwen3.8-27B recipes. Absence selects xhigh
# (template resolves `reasoning_effort|default('xhigh')`). medium renders empty. No quality
# A/B run. Full rationale: docs/runs/2026-09-05-build-comment-consolidation.md#reasoning-effort-pin-1

cat > /usr/share/kinoite/lemonade-recipes/recipe_options.json << 'EOF'
{
  "user.Qwen3.8-27B":      { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.8-27B-Fast": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.8-27B-Q6XL": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.8-27B-Q8XL": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.6-27B":     { "ctx_size": 131072 },
  "user.Qwen3.6-35B-A3B": { "ctx_size": 131072 },
  "user.Qwen3-Coder-30B": { "ctx_size": 262144 }
}
EOF

# Fail the build loudly on a JSON typo rather than shipping a config lemonade rejects.
for f in user_models recipe_options; do
    python3 -m json.tool "/usr/share/kinoite/lemonade-recipes/$f.json" >/dev/null
done

### 2. SELinux: let containers mmap /dev/kfd
# container-selinux grants hsa_device_t {open read write ioctl ...} but NOT map,
# and ROCm mmaps /dev/kfd. Without this every model load dies ~25ms in with an HSA
# abort (exit 134) — looks nothing like a permission problem. The alternative
# (SecurityLabelDisable=true or --ipc=host) turns off SELinux entirely and is not
# worth it. A narrower CIL module granting only map is worth doing if the boolean's
# breadth matters. Full incident: docs/runs/2026-09-05-build-comment-consolidation.md#selinux-map-denial-on-devkfd
#
# Boolean state lives in /var/lib/selinux, so it can't ship in the image — a guarded
# oneshot, no-op after first boot.
for bin in getsebool setsebool; do
    command -v "$bin" >/dev/null || { echo "lemonade.sh: missing $bin" >&2; exit 1; }
done

cat > /usr/lib/systemd/system/lemonade-selinux.service << 'EOF'
[Unit]
Description=SELinux boolean allowing containers to mmap GPU compute devices
Documentation=file:///usr/share/kinoite/lemonade.md
ConditionSecurity=selinux

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'getsebool container_use_devices | grep -q " on$" || setsebool -P container_use_devices on'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

### 3. Rootless Quadlet unit
# /etc, not /usr: podman 5.8.4 only searches /etc/containers/systemd/users{,/$UID}
# for rootless units — the /usr/share equivalent is documented but not scanned.
# users/ (not users/$UID/) — the UID isn't knowable at build time.
mkdir -p /etc/containers/systemd/users
### Recipe seeding
# Merges the image's seeds into the user's config PER KEY on every start. Per-file
# seeding (test -f || install) is all-or-nothing: lemonade's Web UI writes
# user_models.json the first time anyone adds a custom model, and from then on every
# image seed is blocked forever — silently. Per-key merge keeps user entries untouched
# and delivers changed recipes on restart.
#
# The image OWNS the keys it ships: every key present in the baked seed is
# reconciled, not merely added when absent. Add-only failed when a shipped recipe
# CHANGED (2570e9b added `-sm tensor` to the Qwen3.8 recipes; only the brand-new
# keys got it — the existing ones kept their old args, silently).
# Full story: docs/runs/2026-09-05-build-comment-consolidation.md#recipe-seeding-add-only-was-the-first-cut-and-failed
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-seed << 'SEEDEOF'
#!/usr/bin/python3
"""Reconcile baked lemonade recipe seeds into the user's config, per key."""
import json
import os
import sys
import tempfile

PAIRS = (
    ("/usr/share/kinoite/lemonade-recipes/user_models.json", "user_models.json"),
    ("/usr/share/kinoite/lemonade-recipes/recipe_options.json", "recipe_options.json"),
)
dest_dir = os.path.join(os.path.expanduser("~"), ".local/share/lemonade/config")


def load(path):
    try:
        with open(path) as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else None
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as exc:
        print(f"kinoite-lemonade-seed: cannot read {path}: {exc}", file=sys.stderr)
        return None


os.makedirs(dest_dir, exist_ok=True)
for src, name in PAIRS:
    seeds = load(src)
    if not seeds:
        continue
    dest = os.path.join(dest_dir, name)
    cur = load(dest)
    # A corrupt or non-dict user file is left strictly alone: overwriting it would be the
    # data loss this whole approach exists to avoid.
    if cur is None:
        print(f"kinoite-lemonade-seed: leaving {name} untouched", file=sys.stderr)
        continue
    added = [k for k in seeds if k not in cur]
    updated = [k for k in seeds if k in cur and cur[k] != seeds[k]]
    if not added and not updated:
        continue
    merged = dict(cur)
    for k in added + updated:
        merged[k] = seeds[k]
    try:
        fd, tmp = tempfile.mkstemp(dir=dest_dir, prefix=f".{name}.")
        with os.fdopen(fd, "w") as fh:
            json.dump(merged, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, dest)      # atomic; lemonade reads this file on every start
        os.chmod(dest, 0o644)
        note = [f"added {', '.join(added)}"] if added else []
        note += [f"updated {', '.join(updated)}"] if updated else []
        print(f"kinoite-lemonade-seed: {name}: {'; '.join(note)}")
    except OSError as exc:
        print(f"kinoite-lemonade-seed: cannot write {name}: {exc}", file=sys.stderr)
SEEDEOF
python3 -c 'import ast,sys; ast.parse(open("/usr/libexec/kinoite-lemonade-seed").read())'

### Device visibility for the lemonade container
# The gfx120X-only llamacpp-rocm bundle has no kernels for the gfx1036 iGPU.
# `AddDevice=/dev/dri` hands the container every render node including it.
# Layer split survived that by accident; `-sm tensor` dies on first decode.
#
# Visibility (not per-flag): `-dev` restricts only the main model; the MTP draft
# has its own device list. `ROCR_VISIBLE_DEVICES` covers everything.
#
# ROCR not HIP: ROCR indexes KFD GPU-agent list in topology-node order (the order
# the derivation walks). HIP orders by PCI BDF — a coincidence here.
#
# Derived, not literal: DRM numbering reshuffles. The rule is "keep every GPU agent
# of the same gfx target as the most capable one" — needs no index or model name.
#
# Fails open: the file is truncated first, then filled. Every error path leaves an
# EMPTY env file, which means unconstrained (layer split, same as pre-2026-08-30).
# Absent would be fatal (podman treats missing --env-file as error).
# Full rationale: docs/runs/2026-09-05-build-comment-consolidation.md#device-visibility-why-rocr-not-hip-why-derived-not-literal
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-gpus << 'GPUEOF'
#!/bin/bash
# Write ROCR_VISIBLE_DEVICES for lemonade.container, derived from KFD topology.
# Pure /sys: no ROCm, no python, no container. Runs as an ExecStartPre on the host,
# because the value has to be in the container's environment before it is created.
#
# Fail open: an empty output file means "constrain nothing", which is the pre-2026-08-30
# behaviour. Never exits nonzero — a derivation problem must not block the server.
set -u

out="${1:?usage: kinoite-lemonade-gpus <output-env-file>}"
nodes=/sys/class/kfd/kfd/topology/nodes

mkdir -p "${out%/*}" 2>/dev/null || true
: > "$out" 2>/dev/null || {
    echo "kinoite-lemonade-gpus: cannot write $out; starting unconstrained" >&2
    exit 0
}
# From here on the file exists and is empty, so every early exit below is a fall back
# to unconstrained rather than a failed container start. No atomic replace is needed:
# podman reads this only in ExecStart, strictly after this helper has exited.

# ROCR_VISIBLE_DEVICES numbers GPU agents only, in KFD node order. Walk the nodes
# numerically and skip CPU agents (simd_count 0, node 0 here) — the count of GPU
# agents emitted so far IS the index, so no index is ever written down.
agents=$(
    for n in $(ls -1 "$nodes" 2>/dev/null | grep -xE '[0-9]+' | sort -n); do
        p="$nodes/$n/properties"
        [ -r "$p" ] || continue
        read -r simd gfx <<< "$(awk '
            $1 == "simd_count"          { s = $2 }
            $1 == "gfx_target_version"  { g = $2 }
            END                         { print s+0, g+0 }' "$p")"
        [ "$simd" -gt 0 ] 2>/dev/null || continue
        [ "$gfx"  -gt 0 ] 2>/dev/null || continue
        printf '%s %s\n' "$gfx" "$simd"
    done
)
[ -n "$agents" ] || {
    echo "kinoite-lemonade-gpus: no GPU agent found under $nodes; starting unconstrained" >&2
    exit 0
}

# The most capable agent's gfx target is the family to keep; NR-1 is its GPU-agent index.
target=$(printf '%s\n' "$agents" | sort -k2,2nr -k1,1nr | awk 'NR == 1 { print $1 }')
csv=$(printf '%s\n' "$agents" | awk -v t="$target" '$1 == t { printf "%s%d", (n++ ? "," : ""), NR - 1 }')
[ -n "$csv" ] || exit 0

printf 'ROCR_VISIBLE_DEVICES=%s\n' "$csv" > "$out"
total=$(printf '%s\n' "$agents" | wc -l)
echo "kinoite-lemonade-gpus: gfx_target_version $target -> ROCR_VISIBLE_DEVICES=$csv (of $total GPU agents)"
GPUEOF
bash -n /usr/libexec/kinoite-lemonade-gpus

### Browser origin allowlist for a `tailscale serve` front end
# lemonade hardcodes its CORS allowlist to loopback (127.0.0.1, [::1], .localhost) and
# answers every other Origin with 403 {"error": "Origin not allowed"}. Fronting the
# Web UI with `tailscale serve` therefore loads the page but 403s every XHR it makes.
#
# Derived: baking the tailnet name into this public repo would publish it,
# and it goes stale on a node rename. The helper asks tailscaled instead, and only for
# serve rules that actually proxy to lemonade's own port, so a box with no such rule is
# left at loopback-only — unchanged from before this existed.
#
# Exact origins only: `*.ts.net` matches nothing and `*` allows everything. Measured
# against lemonade 11.5.2: docs/runs/2026-09-03-lemonade-origin-allowlist.md
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-origins << 'ORIGEOF'
#!/usr/bin/python3
"""Write LEMONADE_ALLOWED_ORIGINS for lemonade.container from `tailscale serve` config.

Runs as an ExecStartPre on the host, because the value has to be in the container's
environment before podman creates it.

Fail closed: an empty output file means "loopback origins only", which is lemonade's own
default and the behaviour before this helper existed. Never exits nonzero for a runtime
problem — a derivation failure must not block the server. The file is always created,
because podman treats a missing --env-file as fatal.
"""

import json
import os
import subprocess
import sys
from urllib.parse import urlsplit

LOOPBACK = {"127.0.0.1", "localhost", "::1"}

if len(sys.argv) < 2:
    sys.exit("usage: kinoite-lemonade-origins <output-env-file> [backend-port]")
out = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 13305


def warn(msg):
    print(f"kinoite-lemonade-origins: {msg}", file=sys.stderr)


try:
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    open(out, "w").close()
except OSError as exc:
    warn(f"cannot write {out}: {exc}; starting with loopback origins only")
    raise SystemExit(0)
# From here on the file exists and is empty, so every early exit is a fall back to
# loopback-only rather than a failed container start.

try:
    proc = subprocess.run(
        ["tailscale", "serve", "status", "--json"],
        capture_output=True, text=True, timeout=10,
    )
except (OSError, subprocess.SubprocessError) as exc:
    warn(f"cannot run tailscale: {exc}; loopback origins only")
    raise SystemExit(0)
if proc.returncode != 0:
    warn(f"tailscale serve status failed: {proc.stderr.strip()}; loopback origins only")
    raise SystemExit(0)
try:
    cfg = json.loads(proc.stdout)
except ValueError as exc:
    warn(f"unparseable serve config: {exc}; loopback origins only")
    raise SystemExit(0)
if not isinstance(cfg, dict):
    print("kinoite-lemonade-origins: no tailscale serve config; loopback origins only")
    raise SystemExit(0)


def proxies_here(handler):
    """True if this serve handler forwards to lemonade's port on loopback."""
    target = handler.get("Proxy") if isinstance(handler, dict) else None
    if not target:
        return False                      # Path/Text handlers serve files, not us
    parts = urlsplit(target if "//" in target else f"//{target}")
    try:
        return parts.hostname in LOOPBACK and parts.port == port
    except ValueError:                    # malformed port in the serve config
        return False


# Only handlers under "Web" are considered: those are the ones Tailscale fronts with
# HTTP(S), so they are the only ones a browser sends an Origin for. A raw TCPForward is
# a byte pipe with no origin of its own and is deliberately not covered.
tcp = cfg.get("TCP") or {}
origins = []
for hostport, web in (cfg.get("Web") or {}).items():
    handlers = (web or {}).get("Handlers") or {}
    if not any(proxies_here(h) for h in handlers.values()):
        continue
    host, _, listen = hostport.rpartition(":")
    # Tailscale terminates TLS unless the port was served with --http.
    scheme = "http" if (tcp.get(listen) or {}).get("HTTP") else "https"
    default = "80" if scheme == "http" else "443"
    # A browser omits the default port from the Origin header; matching is textual.
    origin = f"{scheme}://{host}" if listen == default else f"{scheme}://{host}:{listen}"
    if origin not in origins:
        origins.append(origin)

if not origins:
    print(f"kinoite-lemonade-origins: no serve rule proxies to port {port}; "
          "loopback origins only")
    raise SystemExit(0)

try:
    with open(out, "w") as fh:
        fh.write("LEMONADE_ALLOWED_ORIGINS=" + ",".join(origins) + "\n")
except OSError as exc:
    warn(f"cannot write {out}: {exc}; loopback origins only")
    raise SystemExit(0)
print("kinoite-lemonade-origins: LEMONADE_ALLOWED_ORIGINS=" + ",".join(origins))
ORIGEOF
python3 -c 'import ast; ast.parse(open("/usr/libexec/kinoite-lemonade-origins").read())'

cat > /etc/containers/systemd/users/lemonade.container << 'EOF'
[Unit]
Description=Lemonade Server (local LLM, containerized ROCm)
Documentation=https://lemonade-server.ai/docs/
Documentation=file:///usr/share/kinoite/lemonade.md

[Container]
Image=ghcr.io/lemonade-sdk/lemonade-server:latest
ContainerName=lemonade

# The image runs as UID 10001, which maps to a subuid by default — bind mounts would
# come back subuid-owned. keep-id makes it you, which also lets the volumes skip :U
# (a recursive chown on every start).
UserNS=keep-id:uid=10001,gid=10001

# GroupAdd=keep-groups removed: measured unnecessary — /dev/kfd and render nodes
# are mode 0666 from systemd-udev's base rules. Sidesteps known rootless flakiness
# (podman#27876, #28364). Full details: docs/runs/2026-09-05-build-comment-consolidation.md#groupaddkeep-groups-removed

# Directory: podman adds every node under it, iGPU included. See docs/reference/gpu-topology.md.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# Unauthenticated API — the 127.0.0.1 prefix keeps it off the tailnet DIRECTLY, but it
# does not stop a host-side reverse proxy: `tailscale serve` in front of this port
# reaches it over loopback and exposes every endpoint, /internal/mcp/* included.
# LEMONADE_API_KEY is the guard there; lemonade only warns about this when it BINDS a
# non-loopback host, so it stays silent behind a proxy. See lemonade.md.
PublishPort=127.0.0.1:13305:13305

# %h is expanded by systemd, not Quadlet. :z not :Z — :Z would relabel the whole
# model cache on every start, since Quadlet builds a new container each time.
# The huggingface cache is the SHARED model store (see vllm.sh) — same HF hub layout,
# so lemonade and vLLM download once and reuse. llama/ and config/ stay lemonade-specific.
Volume=%h/.local/share/models/huggingface:/opt/lemonade/.cache/huggingface:z
Volume=%h/.local/share/lemonade/llama:/opt/lemonade/llama:z
Volume=%h/.local/share/lemonade/config:/opt/lemonade/.cache/lemonade:z

# Mounting this from /usr/share directly fails: container_t can't read usr_t, and
# :z can't fix it because /usr is read-only. Hence the ExecStartPre copy below.
Environment=LEMONADE_DEFAULTS_PATH=/opt/lemonade/.cache/lemonade/defaults.json

# Which GPU agents llama.cpp may use, computed per start by the ExecStartPre below.
# Keep the `%t` BARE. podman-systemd.unit(5) says to write `./%t` for a path starting with a
# specifier, and that advice is for paths meant to resolve against the unit directory — it is
# wrong here and silently so: `quadlet -dryrun` expands `./%t/...` to
# `/etc/containers/systemd/users/%t/...`, a literal `%t` directory that will never exist, and
# podman treats a missing --env-file as fatal. Bare `%t` is passed through verbatim for systemd
# to expand at runtime, which is what this needs. Verified both ways with `quadlet -dryrun`.
EnvironmentFile=%t/kinoite-lemonade/gpus.env

# Browser origins lemonade will accept, computed per start by the ExecStartPre below. Empty
# unless `tailscale serve` fronts this port, and empty means loopback-only. Same bare-`%t`
# rule as above.
EnvironmentFile=%t/kinoite-lemonade/origins.env

[Service]
# First start pulls a multi-GB image against systemd's 90s default.
TimeoutStartSec=900

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/huggingface %h/.local/share/lemonade/llama %h/.local/share/lemonade/config
ExecStartPre=/usr/bin/install -m 0644 /usr/share/kinoite/lemonade-defaults.json %h/.local/share/lemonade/config/defaults.json

# Recipe seeds, reconciled PER KEY: lemonade reads user_models.json every start and its Web UI
# writes the same file when a user adds a custom model, so the seeder rewrites only the keys
# the image ships and leaves every other key alone. Runs on every start, not just the first —
# that is how a CHANGED recipe reaches the box. See the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-seed

# Excludes the iGPU by VISIBILITY before the container exists. Fails open — see the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-gpus %t/kinoite-lemonade/gpus.env

# Lets a `tailscale serve` front end past lemonade's loopback-only CORS check. Fails closed
# to loopback-only — see the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-origins %t/kinoite-lemonade/origins.env 13305

# No [Install] — hand-started on purpose.
EOF

### 4. On-box runbook
# The box won't have this repo checked out when something breaks. Source is docs/how-to/lemonade.md.
install -D -m 0644 /ctx/docs/how-to/lemonade.md /usr/share/kinoite/lemonade.md
