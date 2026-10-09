---
id: RUN-07
title: "Startup hooks are the only way to run project code at start"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
  - tests/unit/45-entrypoint-hooks.sh
---

# RUN-07: Startup hooks are the only way to run project code at start

## Rule

- Before the supervise scan, the entrypoint sources every hook file that
  exists: `$NIXENV_EXTRA_PROFILE/etc/nixenv-hooks.sh` (flake),
  `$APP_MOUNT/.nixenv/hooks.sh` (repo), `$HOME/.nixenv-hooks.sh` (local); then
  calls `nixenv_pre_ssh_start` if defined.
- Hook failures MUST warn, never block startup. The hooks run in their own
  subshell with errexit off, inside a background block next to sshd: a missing
  command, a `set -e` failure or an `exit` ends only that subshell, and the
  project services are started anyway.
- sshd MUST NOT depend on the hooks: its `runsv` is exec'd as PID 1 right away,
  so a hook that fails or hangs never locks the user out.
- The outcome is written to `$HOME/.nixenv-hooks.status`: `starting`,
  `running <hook>`, `ok`, or `failed: <hooks>` / `failed: <hook> aborted (exit N)`.
- Variables a hook sets or exports do NOT reach the services; set them in the
  `sv/<name>/run` script.

## Why

A flake build is sandboxed to `$out` and can't write `$HOME`/`$SVROOT`: declare
the hook at build time (`writeTextDir "etc/nixenv-hooks.sh"`), run it at
container start. Running before the scan lets hooks add services for the same
boot.

Under `set -e`, dash exits the WHOLE script on a "command not found" at the top
level of a sourced file, even inside `. file || echo …`. A project hook calling
a missing `/app/deploy/local/setup.sh` killed PID 1 before sshd started: the
container exited and `start` still reported success.

## How

For restricted projects the entrypoint first waits (≤20s) for the egress proxy
name to resolve (EGR-06), inside the same background block.
