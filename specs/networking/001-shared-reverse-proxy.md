---
id: NET-01
title: "One shared Caddy reverse proxy for all projects"
area: networking
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/07-caddyfile.sh
  - tests/integration/06-proxy-ingress.sh
---

# NET-01: One shared Caddy reverse proxy for all projects

## Rule

- A single `${PREFIX}__proxy` Caddy container (caddy from the store) on the
  shared user network `PROXY_NET`, which every project container joins.
- Caddy serves `*.PROXY_DOMAIN` (`nixenv.localhost`), parses
  `Host = <project>-<port>.<domain>` and proxies to `<prefix>-<project>:<port>`
  by container-name DNS.
- The route regex MUST be limited to project-name characters
  (`[a-zA-Z0-9_-]+`), never `(.+)`.
- With `PROXY_NIP_DOMAIN` set (default `127.0.0.1.nip.io`) the SAME site also
  serves `<project>-<port>-<PROXY_NIP_DOMAIN>` (site address `*.` + the domain
  minus its first label, e.g. `*.0.0.1.nip.io`). Every Host regex — route,
  cross-project guard (NET-04), ingress capture — uses the one suffix from
  `proxy_host_suffix_re`. `proxy_nip_domain` accepts only lowercase DNS
  characters and ≥3 labels (it lands in a regex and a site address); anything
  else, or empty, turns the form off. Dashboard and mitmweb stay on
  `PROXY_DOMAIN` only.
- Caddy binds 80/443 in-container (`ip_unprivileged_port_start=0`); host
  publish maps `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT` (default 80/443; 8080/8443
  for rootless podman).
- 80/443 are published on `127.0.0.1` plus the IPv4 literals in `PROXY_BIND`
  (`proxy_bind_addrs`: validated, deduplicated, loopback always kept; `0.0.0.0`
  replaces the rest). The restricted projects' relays (`EGRESS_PUB`) stay on
  loopback. A non-loopback address warns on every `proxy up`, and the bind
  list is part of `proxy_start_sum`, so a change recreates the proxy.
- `cmd_run` auto-starts the proxy on first run (`PROXY_AUTOSTART=1`) via
  `ensure_proxy_running`, in a subshell so a proxy `die` can't fail `run`.

## Why

Stable HTTPS URLs per project/port without publishing every port. `*.localhost`
doesn't resolve in Safari or in tools that use plain DNS; nip.io is a real name
for 127.0.0.1 — or, with `PROXY_BIND`, for a Tailscale address, so other
devices on the tailnet can open the projects. A separate site block for it would have skipped the
cross-project guard.

## How

`proxy up|reload|stop|status|logs [egress]|renew|remove-cert`. `proxy reload`
regenerates configs and hot-reloads caddy (`caddy reload`) and squid
(`-k reconfigure`) without recreating containers; new relays or published
ports still need `proxy up`. Caddy data (incl. internal CA) persists in
`~/.nixenv/proxy/data`. The bare `PROXY_DOMAIN` (no project prefix) serves the
read-only project dashboard (NET-05).
