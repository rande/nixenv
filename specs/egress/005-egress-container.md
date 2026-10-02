---
id: EGR-05
title: "squid runs in its own egress container"
area: egress
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/08-egress-config.sh
  - tests/integration/07-restricted-egress.sh
---

# EGR-05: squid runs in its own egress container

## Rule

- `egress_up` runs `${PREFIX}__egress` on its own network `EGRESS_NET`
  (`${PROXY_NET}-egress`); only it and Caddy join it, Caddy via alias
  `EGRESS_LINK` = `${PREFIX}__egress-link`. It is `network connect`ed to every
  restricted internal net (and every deploy net).
- It is NOT recreated by `proxy up`/`reload` — squid reloads, mitmproxy restarts
  in place — only when missing, when it still publishes a port, or when its
  `egress.sh` checksum label changed. `proxy up` brings egress up FIRST.
- Its data dir `EGRESS_DATA_DIR` (`~/.nixenv/proxy/egress-data`, 700) is
  separate from Caddy's.
- `write_egress_configs` MUST NOT `rm -rf` the bind-mounted egress dir.

## Why

Recreating Caddy (every restricted `run` does, for relays) used to cut egress
for every project. The container parsing untrusted traffic must never mount
Caddy's CA key. Replacing the dir inode would detach the mount and reloads
would read stale config forever.

## How

Both containers mount that dir read-only at `/etc/egress`; the egress container
mounts `EGRESS_DATA_DIR` at `/data`. Generated in `~/.nixenv/proxy/egress/`: `squid.conf`, `start.sh` (relays + exec
caddy — the proxy's cmd), `egress.sh` (mitmproxy loop + exec squid), plus the
capture files. With no restricted project and no deploy allowlist, the egress
container is removed.
