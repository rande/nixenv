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
  `.config/starship.toml`, `.config/nvim/init.lua` (AstroNvim bootstrap),
  `.tmux.conf`, `.vimrc`, `.ssh/config`)

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
- The runtime container runs **entirely non-root**: `run` passes
  `--user $(id -u):$(id -g)` (+ `--userns=keep-id` for podman, via
  `engine_userns`) and `--hostname <project>`. The login user `app` comes from
  generated `passwd`/`group`/`shadow` files (`write_passwd_files`, in
  `<project>/`) bind-mounted at `/etc/passwd|group|shadow`; `shadow` has an empty
  password for the open SSH login. Code, home, and databases are **named
  volumes** `nixenv_<project>_app` → `/app`, `nixenv_<project>_home` →
  `/home/app`, `nixenv_<project>_databases` → `/databases`
  (`app_volume`/`home_volume`/`db_volume`). `ensure_volumes` only creates
  MISSING volumes and **chowns ONLY the freshly-created ones** to your uid via a
  one-time throwaway root helper (`-u 0 … chown`) — existing volumes are never
  mounted by the helper, so their data is never touched. A fresh home volume is
  seeded (copy, non-destructive) from the host seed dir `<project>/home`.
  `/databases` is empty per-project storage for DB data files. This is
  what lets a non-root container use named volumes. The entrypoint does NO root
  ops; it writes `.zshenv`, sshd config, host keys, and the runit tree under the
  writable `$HOME`. `init <git-url>` clones into the app volume via the runtime
  image run as your uid. `build <project>` extracts the flake from the app volume.
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
  configures an **unprivileged** `sshd` on port `$SSHD_PORT` (2222) — host keys,
  config, and the runit service tree all under `$HOME/.nixenv-sshd`, no privsep
  (single user, runs as that user) — and `exec`s runit's per-service supervisor
  `runsv` (by **absolute** path) as PID 1. `flake.nix` includes `openssh` and
  `runit`. We use `runsv <dir>` rather than `runsvdir`, because `runsvdir` spawns
  its `runsv` children via `PATH` and that lookup fails here; exec'ing `runsv`
  directly avoids it. `run` maps the project's random host port → 2222.
- Extra published ports live one-per-line in `<project>/ports` (helper: `expose`
  / read in `cmd_run`). A bare number maps `127.0.0.1:N:N`; a `:`-spec is passed
  to `docker -p` verbatim. The SSH port is always published on `127.0.0.1`.
- Per-project tooling: `build <project> [--dir=<path>]` (`cmd_build_project`)
  copies the project flake into `<project>/flake/` and
  `nix profile install path:/flake#$PROJECT_ATTR` into `/nix/var/nix/profiles/proj-<name>`
  (`project_profile`) in the same store. Default copies just `flake.nix`/`.lock`
  from `repo/`; `--dir=<path>` (relative to repo, or absolute) copies a WHOLE
  folder so a flake with local file references resolves. `run` passes the profile
  path as `NIXENV_EXTRA_PROFILE`; `.zshenv` prepends its `bin` to `PATH` (ahead of
  base) when present. `delete` removes the profile; `init --build` runs the
  default mode after scaffolding.
- The Claude CLI (`claude-code` from `nixpkgs-unstable`) is on the shared
  profile. Two shared paths are bind-mounted **rw** into every container so one
  login + config is shared: `$HOME/.nixenv/claude` → `/home/app/.claude`
  (`CLAUDE_DIR`) and `$HOME/.nixenv/claude.json` → `/home/app/.claude.json`
  (`CLAUDE_JSON`). `.claude.json` lives in the home root (not inside `.claude`),
  so it's shared as its own file; `prepare_claude_share` seeds it (restoring the
  newest `.claude/backups/` if present) before each `run`.
- Terminal session persistence uses **zmx** (github:neurosnap/zmx), installed in
  the base flake as a **prebuilt static-musl binary** (`builtins.fetchTarball` +
  `runCommand`) because its source build needs bubblewrap/user namespaces the
  builder container can't create. The base build therefore runs `--impure`
  (fetchTarball has no pinned hash); `BUILDER_PRIVILEGED=1` is the fallback for
  other source builds that need bwrap. `write_host_ssh_config` writes
  `<project>/ssh/config` (Host
  `<name>`/`<name>.*` → 127.0.0.1:port, `RemoteCommand zmx attach %k`,
  `ControlMaster`), and `ssh-config --install` adds the `Include` glob to
  `~/.ssh/config` so `ssh <project>` works. `nixenv ssh`/`shell` connect directly
  (plain zsh, no zmx). The prompt (starship) shows `$NIXENV_PROJECT`,
  `$ZMX_SESSION`, and the hostname (= project name). No zellij anywhere.
- `run <project>` (no cmd) starts a **detached** service container named
  `<prefix>-<project>` with `-p <project-port>:22`. `ssh`/`shell` auto-start it;
  `shell` uses `docker exec` (no key needed), `ssh` uses the host `ssh` client.
  `stop` removes the container; `logs` follows it.

## Commands

`build [project]`, `init <project> [git-url] [--build]`, `run <project>`,
`ssh <project>`, `ssh-config [--install]`, `shell <project>`,
`expose <project> <port>…`, `up`, `stop`, `logs`, `delete`/`rm`, `projects`,
`update`, `status`, `clean`, `install`, `uninstall`. See `./nixenv.sh --help` and
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
