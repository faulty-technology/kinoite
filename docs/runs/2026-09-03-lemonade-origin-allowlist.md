---
date: 2026-09-03
subject: lemond CORS origin allowlist behind tailscale serve
harness: ad-hoc; throwaway `podman run --rm` of the shipped image on a spare port, curl with a forced Origin header
box: kinoite-north
---

# lemond CORS origin allowlist behind tailscale serve

## What was measured

`tailscale serve` fronts `127.0.0.1:13305` at `https://<node>.<tailnet>.ts.net`.
The Web UI page loaded, but every request it made came back 403
`{"error": "Origin not allowed"}`, which presents as a half-broken UI rather than
a rejection — a document navigation carries no `Origin` header, so only the XHRs
are refused.

lemond 11.5.2, image `ghcr.io/lemonade-sdk/lemonade-server:latest`. Against the
running server first, to confirm the shape:

    Origin: https://<node>.<tailnet>.ts.net   403
    Origin: http://localhost:13305            200
    (no Origin header)                        200

`strings` on `/opt/lemonade/lemond` gives the whole mechanism: `setup_cors`,
`is_loopback_origin`, the literals `127.0.0.1` / `[::1]` / `.localhost`, and one
environment variable, `LEMONADE_ALLOWED_ORIGINS`. There is no `config.json` key —
`lemonade config set` cannot reach this.

Accepted values were then swept in a throwaway container on port 13399, so the
live server was never restarted.

## Numbers

Response code per `Origin`, by value of `LEMONADE_ALLOWED_ORIGINS`:

| value | tailnet origin | unrelated origin | loopback origin |
| --- | --- | --- | --- |
| unset | 403 | 403 | 200 |
| `https://<node>.<tailnet>.ts.net` | 200 | 403 | 200 |
| `https://a,https://b` | 200 | 403 | 200 |
| `*` | 200 | 200 | 200 |
| `*.ts.net` | 403 | 403 | 200 |

Exact scheme-plus-host matches only, comma-separated. `*` is the only wildcard
that does anything; subdomain patterns match nothing and fail silently, which is
the trap — `*.ts.net` looks like it should work. Loopback stays allowed
regardless of the variable.

End-to-end through the shipped path (helper output -> podman `--env-file` ->
container environment): tailnet origin 200 with
`Access-Control-Allow-Origin: https://<node>.<tailnet>.ts.net` echoed back,
unrelated origin 403.

## What it means

The value is machine-specific and this repo is public, so it is derived at start
rather than baked: `kinoite-lemonade-origins` reads `tailscale serve status --json`
(which needs no root) and emits an origin only for serve rules whose `Proxy`
targets lemonade's own port on loopback. A box with no such rule gets an empty
file, which is loopback-only — the behaviour before the helper existed.

Verified on this box's live serve config: port 13305 yields
`https://<node>.<tailnet>.ts.net` (443 elided, as a browser elides it), port 8000
yields `https://<node>.<tailnet>.ts.net:8443` from the vLLM rule, and an
unproxied port yields an empty file.

A second finding, not the one being chased: fronting the port with `tailscale
serve` defeats the loopback bind that `lemonade.container` relies on for
isolation. Every endpoint including `/internal/mcp/*`, which launches processes,
is reachable unauthenticated from any tailnet node. lemond has a startup warning
for exactly this, but its own strings show it fires only when the server *binds*
a non-loopback host — behind a proxy it stays silent. `LEMONADE_API_KEY` is the
guard; whether the Web UI authenticates cleanly against it was not tested.
