# CLAUDE.md

Guidance for working in this repository.

## What this is

A local container dev-environment tool. `nixenv.sh` provisions a shared Nix
store inside a standalone Docker volume and runs per-project `debian:stable-slim`
containers that mount that store read-only. The goal is fast, disposable project
containers that all share one pinned toolchain.

## Single source of truth

`nixenv.sh` is **self-contained**. All supporting files are embedded inside it as
single-quoted heredocs in the `materialize_context()` function:

- `flake.nix` — the shared toolchain (delimiter `NIXENV_FLAKE`)
- `Dockerfile` — reference only, not used by the build (`NIXENV_DOCKERFILE`)
- `entrypoint.sh` — runtime container entrypoint (`NIXENV_ENTRYPOINT`)
- `home-skel/*` — the per-project home template (`.zshrc`, `.gitconfig`,
  `.config/starship.toml`, `.config/zellij/config.kdl`, `.tmux.conf`, `.vimrc`,
  `.ssh/config`)

On every command run, `materialize_context()` writes these into `$CONTEXT_DIR`
(default `~/.nixenv/context`) and the build runs from there. There are **no
standalone `flake.nix` / `runtime/` files in the repo** — do not recreate them.
To change any embedded file, edit the corresponding heredoc inside `nixenv.sh`.

## Editing embedded files — rules

- Heredoc delimiters are single-quoted (`<<'NIXENV_…'`), so content is written
  verbatim with no shell expansion. Keep them quoted.
- In `entrypoint.sh`, `$PROFILE` is expanded by the entrypoint at container
  start, while `\$HOME` is intentionally left literal so zsh expands it later.
  Preserve the backslashes.
- Each embedded file uses a unique delimiter so nested heredocs (the entrypoint
  writes a `.zshenv` with `<<EOF`) don't clash. Don't reuse delimiter names.
- `flake.lock` is never written by the script, so it persists in `$CONTEXT_DIR`
  across runs.

## Architecture details

- The shared profile lives at `/nix/var/nix/profiles/shared` inside the volume.
  `build` resets it (`rm` the profile + generation links) before
  `nix profile install` so flake changes actually take effect.
- The runtime container runs as a non-root `app` user. The project `home/` is
  bind-mounted read-only at `/seed` and **copied** into `/home/app` by the
  entrypoint, so `.ssh` perms (`700`/`600`) can be enforced. The repo is mounted
  at `/app` (the WORKDIR). `APP_UID`/`APP_GID` are set to the host uid/gid so the
  repo stays writable on Linux.
- Git identity is per project in `home/.gitconfig.identity`, included by the
  project `.gitconfig`. `init` prompts for it (or uses `GIT_USER_NAME` /
  `GIT_USER_EMAIL`).

## Commands

`build`, `init <project> [git-url]`, `run <project> [cmd...]`, `up`, `shell`,
`projects`, `update`, `status`, `clean`. See `./nixenv.sh --help` and `README.md`.

## Conventions

- Keep the script POSIX-friendly where it runs as `/bin/sh` (the entrypoint) and
  Bash for `nixenv.sh` itself (`#!/usr/bin/env bash`, `set -euo pipefail`).
- Support macOS Bash 3.2: guard empty-array expansions and avoid Bash-4-only
  features.
- `projects/` is git-ignored and holds user data (SSH keys, repos) — never
  commit it, and avoid destructive operations on it.

## Verifying changes

After editing `nixenv.sh`:

```sh
bash -n nixenv.sh                 # syntax check the script
CONTEXT_DIR=/tmp/ctx ./nixenv.sh status   # materialise embedded files
sh -n /tmp/ctx/entrypoint.sh      # syntax check the generated entrypoint
```

A full `build` + `run` requires a working Docker daemon.
