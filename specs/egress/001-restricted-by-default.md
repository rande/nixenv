---
id: EGR-01
title: "Egress restriction is on by default"
area: egress
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/09-allow-restrict.sh
  - tests/integration/07-restricted-egress.sh
---

# EGR-01: Egress restriction is on by default

## Rule

- A project is restricted unless `<project>/unrestricted` exists
  (`restrict <p> off`, `init --unrestricted`); `restrict <p> on` removes it.
- A restricted project runs on its own `--internal` network
  `<prefix>_<p>_egress` with NO published ports; its ssh/extra ports are
  published by the PROXY container and socat-relayed.
- Its only way out is squid in the egress container (`EGRESS_NAME`, port
  `EGRESS_PORT` 3128, not published); `cmd_run` passes
  `NIXENV_EGRESS_PROXY=http://<egress>:3128`. The entrypoint exports
  HTTP(S)_PROXY/NO_PROXY into `.zshenv` and appends a marker-guarded
  `ProxyCommand socat - PROXY:…` block to `~/.ssh/config`, and writes
  `.npmrc`/`.yarnrc` blocks (yarn 1 ignores env vars).

## Why

Kernel-enforced no-route-out; `-p` doesn't work on internal networks.

## How

Squid ACLs are keyed by the internal net's subnet (`net_subnet`: docker
`.IPAM.Config`, podman `.Subnets`). The entrypoint gets the prefix as
`NIXENV_CONTAINER_PREFIX` for NO_PROXY and the ssh `!<prefix>-*` bypass, so
sibling containers are reached directly.

From inside, external DNS fails by design (`ping`, `dig`, QUIC never work);
`getent hosts <prefix>-egress` works, `getent hosts google.com` fails. UDP/QUIC
isn't proxied and `clone_repo` runs once unrestricted — known limits.
