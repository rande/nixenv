# CLAUDE.md

Guidance for working in this repository.

## What this is

A local container dev-environment tool. `nixenv.sh` provisions a shared Nix
store inside a standalone container volume and runs per-project
`debian:stable-slim` containers that mount that store read-only. The goal is
fast, disposable project containers that all share one pinned toolchain.

Works with **docker or podman**: `resolve_engine` picks the binary (env
`CONTAINER_ENGINE` → remembered `~/.nixenv/engine` → auto-detect, prompting if
both are installed) into `$ENGINE`; every container call goes through `$ENGINE`,
and `img()` prefixes `docker.io/` for podman short names. Don't hardcode
`docker` in new code — use `"$ENGINE"` and wrap image refs in `img`.

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
  writes `.zshenv` with `<<EOF` and the sshd `run` script with `<<RUN`) don't
  clash with the outer `NIXENV_ENTRYPOINT`. Don't reuse delimiter names.
- `flake.lock` is never written by the script, so it persists in `$CONTEXT_DIR`
  across runs.

## Architecture details

- The shared profile lives at `/nix/var/nix/profiles/shared` inside the volume.
  `build` resets it (`rm` the profile + generation links) before
  `nix profile install` so flake changes actually take effect.
- The runtime container runs as a non-root `app` user. The project `home/` is
  bind-mounted read-only at `/seed` and **copied** into `/home/app` by the
  entrypoint, so `.ssh` perms (`700`/`600`) can be enforced. The code lives in a
  per-project **named Docker volume** `<project>_app` (helper `repo_volume`),
  mounted at `/app` (the WORKDIR) — not a host bind-mount. `init <project>
  <git-url>` clones into that volume by running the runtime image (debian) with
  the shared store mounted and the entrypoint in command mode (`git clone …`),
  so it uses the store's git + the project's SSH keys (requires `build` first).
  The entrypoint chowns `/app` to `APP_UID`/`APP_GID` (host uid/gid).
- Git identity is per project in `home/.gitconfig.identity`, included by the
  project `.gitconfig`. `init` prompts for it (or uses `GIT_USER_NAME` /
  `GIT_USER_EMAIL`).
- For an `http(s)` clone URL, `init` also prompts (or uses `GIT_HTTP_USER` /
  `GIT_HTTP_TOKEN`) and stores credentials via git's `store` helper:
  `home/.git-credentials` (mode 600) + `home/.gitconfig.credentials`, both
  included by `home/.gitconfig`. `configure_git_credentials` runs before
  `clone_repo`, so the clone is authenticated.
- Projects always live in `$HOME/.nixenv/projects` (hardcoded, not an env
  override). Each `<project>/home` is the only host-side per-project data, plus
  a `port` file holding the project's stable random SSH port (`project_port`).
- The entrypoint has two modes. With **args** it runs them once as the app user
  (ephemeral `run <project> cmd...`). With **no args** (service mode) it
  configures `sshd` — privsep user `sshd` + `/var/empty`, host keys in
  `/etc/ssh`, an `authorized_keys` assembled from any `home/.ssh/*.pub` — writes
  a `runit` service at `/etc/service/sshd`, and `exec`s `runsvdir` as PID 1.
  `flake.nix` therefore includes `openssh` and `runit`.
- The Claude CLI (`claude-code` from `nixpkgs-unstable`) is on the shared
  profile. Two shared paths are bind-mounted **rw** into every container so one
  login + config is shared: `$HOME/.nixenv/claude` → `/home/app/.claude`
  (`CLAUDE_DIR`) and `$HOME/.nixenv/claude.json` → `/home/app/.claude.json`
  (`CLAUDE_JSON`). `.claude.json` lives in the home root (not inside `.claude`),
  so it's shared as its own file; `prepare_claude_share` seeds it (restoring the
  newest `.claude/backups/` if present) before each `run`.
- `run <project>` (no cmd) starts a **detached** service container named
  `<prefix>-<project>` with `-p <project-port>:22`. `ssh`/`shell` auto-start it;
  `shell` uses `docker exec` (no key needed), `ssh` uses the host `ssh` client.
  `stop` removes the container; `logs` follows it.

## Commands

`build`, `init <project> [git-url]`, `run <project> [cmd...]`, `ssh <project>`,
`shell <project>`, `up`, `stop`, `logs`, `delete`/`rm`, `projects`, `update`,
`status`, `clean`, `install`, `uninstall`. See `./nixenv.sh --help` and
`README.md`. `delete` prints the commands (container/volume/home removal) and
prompts before running; `resolve_engine` returns non-zero (not `die`) when no
engine is found so host-file deletion still works.

`install`/`uninstall` copy the single self-contained script to `INSTALL_DIR`
(default `/usr/local/bin`) as `INSTALL_NAME` (default `nixenv`); they run before
`materialize_context` and need neither Docker nor the context.

## Conventions

- Keep the script POSIX-friendly where it runs as `/bin/sh` (the entrypoint) and
  Bash for `nixenv.sh` itself (`#!/usr/bin/env bash`, `set -euo pipefail`).
- Support macOS Bash 3.2: guard empty-array expansions and avoid Bash-4-only
  features.
- `$HOME/.nixenv/projects/` holds user data (SSH keys, per-project home) — it
  lives outside the repo; never commit it and avoid destructive operations on it.

## Verifying changes

After editing `nixenv.sh`:

```sh
bash -n nixenv.sh                 # syntax check the script
CONTEXT_DIR=/tmp/ctx ./nixenv.sh status   # materialise embedded files
sh -n /tmp/ctx/entrypoint.sh      # syntax check the generated entrypoint
```

A full `build` + `run` requires a working Docker daemon.
