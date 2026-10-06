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
- Caddy binds 80/443 in-container (`ip_unprivileged_port_start=0`); host
  publish maps `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT` (default 80/443; 8080/8443
  for rootless podman).
- `cmd_run` auto-starts the proxy on first run (`PROXY_AUTOSTART=1`) via
  `ensure_proxy_running`, in a subshell so a proxy `die` can't fail `run`.

## Why

Stable HTTPS URLs per project/port without publishing every port.

## How

`proxy up|reload|stop|status|logs [egress]|renew|remove-cert`. `proxy reload`
regenerates configs and hot-reloads caddy (`caddy reload`) and squid
(`-k reconfigure`) without recreating containers; new relays or published
ports still need `proxy up`. Caddy data (incl. internal CA) persists in
`~/.nixenv/proxy/data`. The bare `PROXY_DOMAIN` (no project prefix) serves the
read-only project dashboard (NET-05).
