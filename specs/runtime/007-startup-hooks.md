---
id: RUN-07
title: "Startup hooks are the only way to run project code at start"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
---

# RUN-07: Startup hooks are the only way to run project code at start

## Rule

- Before the supervise scan, the entrypoint sources every hook file that
  exists: `$NIXENV_EXTRA_PROFILE/etc/nixenv-hooks.sh` (flake),
  `$APP_MOUNT/.nixenv/hooks.sh` (repo), `$HOME/.nixenv-hooks.sh` (local); then
  calls `nixenv_pre_ssh_start` if defined.
- Hook failures MUST warn, never block startup.

## Why

A flake build is sandboxed to `$out` and can't write `$HOME`/`$SVROOT`: declare
the hook at build time (`writeTextDir "etc/nixenv-hooks.sh"`), run it at
container start. Running before the scan lets hooks add services for the same
boot.

## How

For restricted projects the entrypoint first waits (≤20s) for the egress proxy
name to resolve (EGR-08).
