---
id: DEV-01
title: "Developing nixenv inside nixenv"
area: dev
applies-to:
  - "dev/**"
  - "examples/**"
  - "DEVELOPING.md"
enforced-by:
  - tests/unit/35-dev-environment.sh
  - tests/integration/18-dev-engines.sh
---

# DEV-01: Developing nixenv inside nixenv

## Rule

- `dev/engines.sh up <p>` (host side) starts two PRIVILEGED sidecars
  `<prefix>__<p>-dind` and `<prefix>__<p>-podman` (rootful) serving 0666 sockets
  in volume `<prefix>_<p>_engine`, mounted at `/var/run/nixenv` via ONE line
  appended to `extra-parameters` (`wire_project`, idempotent).
- Sidecars mount the project's home and app volumes at the SAME paths.
- `dev/flake.nix` (build with `--dir=dev`) wraps `docker`/`podman` to those
  sockets and puts `nixenv` on PATH execing the CHECKOUT's `nixenv.sh`;
  `nixenv-docker`/`nixenv-podman` set `CONTAINER_ENGINE`,
  `HOME=$real/.nixenv-dev/<engine>` and default `CONTAINER_PREFIX=nixdev`.
- Every nixenv state path MUST follow `$HOME`.

## Why

A project container can't run an engine. The nested nixenv bind-mounts paths
the daemon resolves on its own filesystem. Two engines sharing one `~/.nixenv`
would make their proxies fight; the prefix keeps nested objects from colliding
with a hosted nixenv. Rootful podman rejects `--userns=keep-id`.

## How

podman is wrapped via `--remote`; the real clients are referenced, not
installed, to avoid `bin/` collisions. The checkout path in `dev/flake.nix` is a
double-quoted Nix string, so its `${` is escaped `\${`. The dev hook writes
`~/.nixenv/engine` once so the nested nixenv doesn't prompt. `examples/hello`
(nginx on 0.0.0.0:8080, paths under `/home/app/.nixenv-run/hello`, `-e` for the
pre-config error log) is the nested smoke test. `engines.sh` sources nixenv
for naming helpers: `$NIXENV_SH`, else the repo, else the installed one
(refusing one that lacks the helpers). `tests/lib.sh` pins
`NIX_VOLUME=nixenv__nixos_store` so the `nxt` suite reuses the built store.
