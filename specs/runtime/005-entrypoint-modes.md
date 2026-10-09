---
id: RUN-05
title: "Entrypoint: command mode and service mode"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
---

# RUN-05: Entrypoint: command mode and service mode

## Rule

- With arguments, the entrypoint runs them once as the app user (ephemeral
  `run <project> cmd…`) and exits.
- With no arguments it configures an unprivileged sshd on `$SSHD_PORT` (2222,
  no privsep, under `$HOME/.nixenv-sshd`) and `exec`s runit's `runsv` by
  ABSOLUTE path as PID 1 — never `runsvdir`. The egress wait, the startup
  hooks and the project services' `runsv`s run in a background block started
  just before that `exec` (RUN-07); the services' `runsv`s are re-parented to,
  and reaped by, PID 1.

## Why

`runsvdir` spawns its `runsv` children via PATH and that lookup fails here.

## How

`run` publishes the project's random host port → 2222 on 127.0.0.1 (or relays
it through the proxy for restricted projects, EGR-01).
