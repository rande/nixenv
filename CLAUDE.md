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
  `.vimrc`, `.gitignore`, `.ssh/config`)

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
  (`app_volume`/`home_volume`/`db_volume`). The app volume's container mount path
  is customisable per project: `init --app-path=/path` (or `APP_MOUNT=`) stores it
  in `<project>/app_mount` and `project_app_mount` reads it (default `/app`). ONLY
  the runtime container and its entrypoint honour it — `cmd_run` mounts the volume
  there (`-v $appv:$appmnt`, `-w $appmnt`, `-e NIXENV_APP_MOUNT`), the entrypoint
  exports `NIXENV_APP_MOUNT` into `.zshenv` (so ssh/zmx shells `cd` there and
  service discovery reads `$APP_MOUNT/.nixenv/sv`), and `cmd_shell` uses it as its
  workdir. The seed/clone/build/sync helpers keep mounting the volume at a
  throwaway `/app` because the repo lands at the volume root regardless of mount
  path. `ensure_volumes` creates any missing
  volume, then a one-time root helper (`-u 0`) seeds a fresh/empty home from
  `<project>/home`, drops a `.keep` into empty `/app`/`/databases`, and chowns to
  your uid ONLY when the root isn't already yours (self-heals wrong-owned volumes;
  correctly-owned data is untouched). The `.keep` matters: **Docker Desktop resets
  an EMPTY named volume's ownership to root on the next mount**, wiping the chown —
  a non-empty volume keeps it. `clone_repo` removes `/app/.keep` before cloning and
  ignores it in the empty-check. `/databases` is empty per-project storage. This is
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
- Custom `/etc/hosts` is file-driven, not `--add-host` (which can't change on a
  live container and, with a bind-mounted `/etc/hosts`, the engine ignores).
  `cmd_run` always bind-mounts a writable `$pdir/etc-hosts` at `/etc/hosts` (a
  host file we own) so the non-root **entrypoint** can rebuild it on every start
  (guarded by `[ -w /etc/hosts ]`). The rebuild = base localhost lines +
  `127.0.1.1 <hostname>` + two optional sources, in order: (1) the project
  flake's declared entries, shipped in its profile as
  `$NIXENV_EXTRA_PROFILE/etc/hosts.extra` (the template uses
  `pkgs.writeTextDir "etc/hosts.extra" ''…''` in `buildEnv.paths`); (2) the
  host-side `<project>/hosts.extra` (local-only), bind-mounted at
  `/etc/hosts.extra:ro` when present. Rebuild-not-append keeps it idempotent, but
  it does replace the engine's dynamic container-IP line (we substitute
  `127.0.1.1 <hostname>`). The `host <project> <name:ip>…` helper appends
  converted `ip<TAB>name` lines to the host-side `hosts.extra`; flake entries are
  the versioned/team-shared path. `$hostsmount` is an empty-guarded unquoted var.
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
  `~/.ssh/config` so `ssh <project>` works. `./nixenv.sh ssh`/`shell` connect directly
  (plain zsh, no zmx). The prompt (starship) shows `$NIXENV_PROJECT`,
  `$ZMX_SESSION`, and the hostname (= project name). No zellij anywhere.
- `run <project>` (no cmd) starts a **detached** service container named
  `<prefix>-<project>` with `-p <project-port>:22`. `ssh`/`shell` auto-start it;
  `shell` uses `docker exec` (no key needed), `ssh` uses the host `ssh` client.
  `stop` removes the container; `logs` follows it.
- Shared reverse proxy (`cmd_proxy`, `nixenv proxy up|stop|status|logs`): a single
  `${PREFIX}-proxy` Caddy container (caddy is in the base flake, run from the store)
  on a shared user network `PROXY_NET` (`nixenv_net`) that every project container
  auto-joins (`ensure_proxy_net` + `--network` in `cmd_run`). Caddy serves
  `*.PROXY_DOMAIN` (`nixenv.localhost`), regex-parses `Host` =
  `<project>-<port>.<domain>` and `reverse_proxy nixenv-{re.route.1}:{re.route.2}`
  by container name (docker/podman-netavark DNS). It binds 8080/8443 in-container
  (non-root); host publish maps `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT` (default 80/443;
  use 8080/8443 for podman rootless). TLS: `proxy_make_cert` uses `mkcert` ONLY if
  the binary is present (`have mkcert` → wildcard `*.PROXY_DOMAIN` into
  `~/.nixenv/proxy/certs`), else `write_caddyfile` emits `tls internal`. It only runs
  `mkcert -install` (the step that may prompt for a password) when the CA isn't
  already present, and prints exactly what that does first; `PROXY_MKCERT_INSTALL=0`
  skips trusting, and the `run` auto-start path forces it to `0` so `run` never
  prompts (explicit `proxy up` defaults to `1`). `proxy renew` reissues the cert;
  `proxy remove-cert` deletes nixenv's cert (falls back to internal CA) and prints
  the `mkcert -uninstall` command rather than running it (it affects all your certs). Caddy data
  (incl. internal CA) persists in `~/.nixenv/proxy/data`. `*.localhost` auto-resolves
  to 127.0.0.1 in Chrome/Firefox; Safari needs a hosts line. `cmd_run` auto-starts
  the proxy on the first project `run` via `ensure_proxy_running` (`PROXY_AUTOSTART=1`
  default; wrapped in a subshell so a `cmd_proxy` `die` can't fail `run`; no-op when
  already running).

## Commands

**Always invoke the tool as `./nixenv.sh <command>` from the repo — not the
installed `nixenv`.** The installed `/usr/local/bin/nixenv` is a snapshot from
the last `./nixenv.sh install`; while iterating on `nixenv.sh` it will be stale,
so all examples and instructions must use `./nixenv.sh`.

`build [project]`, `init <project> [git-url] [--build]`, `run <project>`,
`ssh <project>`, `ssh-config [--install]`, `shell <project>`,
`expose <project> <port>…`, `host <project> <name:ip>…`,
`proxy [up|stop|status|logs]`, `up`, `stop`, `logs`, `delete`/`rm`,
`sync-home <project>`, `projects`, `update`, `status`, `clean`, `install`,
`uninstall`. See `./nixenv.sh --help` and `README.md`. `delete` prints the
commands (container/volume/home removal) and prompts before running;
`resolve_engine` returns non-zero (not `die`) when no engine is found so
host-file deletion still works.

`sync-home <project>` (`cmd_sync_home`) refreshes the home volume's dotfiles
into an EXISTING volume (the seed→volume copy is otherwise one-time, so template
edits like the AstroNvim pin don't propagate on their own). It layers, via a root
helper, the embedded `home-skel` first, then per-project overrides committed at
`<repo>/.nixenv/home/` (which win), backing up overwritten files to
`~/.nixenv/home-backups/<ts>` in the volume and leaving nvim plugins, shell
history, and git identity/credentials untouched. It also refreshes the host seed
(`<project>/home`) so a from-empty re-seed carries the same skeleton. Mounts the
app volume read-only to read the repo overrides; asks for confirmation first.

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
