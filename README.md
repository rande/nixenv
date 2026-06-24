# nixenv

A self-contained shell tool for spinning up disposable, per-project development
containers that share one common set of tools through a single Nix store.

Instead of baking every tool into a Docker image, `nixenv.sh` downloads all
dependencies once into a standalone Docker volume (the Nix store) and lets each
project container mount that store read-only. Containers start instantly and
every project shares the same pinned toolchain.

## How it works

1. **Self-contained script.** Everything — `flake.nix`, a reference
   `Dockerfile`, the runtime entrypoint, and the home skeleton — is embedded in
   `nixenv.sh`. On every run it writes these into `$CONTEXT_DIR`
   (default `~/.nixenv/context`) and builds from there. You can copy just
   `nixenv.sh` anywhere and it recreates its own context.
2. **Standalone volume.** A named Docker volume (`nixos-store`) holds `/nix`.
3. **Builder container.** A short-lived `nixos/nix` container realises every
   dependency from the flake into the volume and installs them into a shared
   profile (`/nix/var/nix/profiles/shared`) that also lives in the volume.
4. **Runtime container.** A lightweight `debian:stable-slim` container mounts the
   volume read-only at `/nix`, creates a non-root `app` user, and runs `sshd`
   under the `runit` supervisor as a background service — so you SSH into it.
   Nix binaries reference their own loader/libs by absolute `/nix` path, so the
   slim base's libc is irrelevant.

## Requirements

- Docker or Podman
- Bash

No host Nix install is needed — all Nix work happens inside containers.

### Container engine

`nixenv.sh` auto-detects `docker` or `podman`. If only one is installed it uses
it; if **both** are present it asks which to use the first time and remembers
the answer in `~/.nixenv/engine`. Override anytime with
`CONTAINER_ENGINE=docker|podman`, or delete that file to be asked again. For
Podman, image names are automatically qualified with `docker.io/`.

## Install (optional)

Install the single self-contained script onto your `PATH` so you can call
`nixenv` from anywhere:

```sh
./nixenv.sh install               # copies to /usr/local/bin/nixenv
```

Override the location or name with `INSTALL_DIR` / `INSTALL_NAME`, and remove it
with `./nixenv.sh uninstall`. Once installed you can use `nixenv <command>`
instead of `./nixenv.sh <command>`.

## Quick start

```sh
./nixenv.sh build                 # download all deps into the volume (slow once)
./nixenv.sh init myapp            # scaffold a project, prompts for git identity
./nixenv.sh run myapp             # start the service (prints the SSH port)
./nixenv.sh ssh myapp             # SSH in as 'app'
```

Clone a repo while initialising (cloned into the project's app volume):

```sh
./nixenv.sh init myapp git@github.com:me/app.git
```

Don't want to set up keys? `./nixenv.sh shell myapp` drops you straight into an
interactive `zsh` via `docker exec` (no SSH key needed).

## Commands

- `build` — (re)write context, then download all flake deps into the volume.
- `init <project> [git-url]` — scaffold the project, prompt for git name/email,
  assign a stable random SSH port, and optionally clone `git-url` into the app
  volume. For an `http(s)` URL it also prompts for a username + Personal Access
  Token and stores them (see [HTTPS credentials](#https-credentials)).
- `run <project>` — start the project as a background service (`sshd` under
  `runit`) and print its SSH port.
- `ssh <project>` — SSH into the running service (auto-starts it).
- `shell <project>` — interactive `zsh` via `docker exec` (no SSH key needed).
- `expose <project> <port>…` — publish extra port(s) (see
  [Exposing ports](#exposing-ports)).
- `up <project>` — build if needed, then start the service.
- `stop <project>` — stop and remove the project's service container.
- `logs <project>` — follow the service container logs.
- `delete <project>` (alias `rm`) — permanently remove a project: its
  container(s), code volume, and home dir. Prints the exact commands it will run
  and asks for confirmation first.
- `projects` — list projects with their SSH port and running state.
- `update` — refresh `flake.lock`, then rebuild into the volume.
- `status` — show context, volume, and shared-profile state.
- `clean` — delete the standalone volume (removes all shared packages).
- `install` / `uninstall` — copy this script onto your `PATH` (as `nixenv`) /
  remove it.

## SSH access

Each project is assigned a **random host port once**, stored in
`~/.nixenv/projects/<name>/port` and shown by `init` and `projects`. The service
container runs `sshd` (supervised by `runit`) and maps that host port to port 22
inside the container.

```sh
./nixenv.sh ssh myapp                       # convenience wrapper
ssh -p <port> app@127.0.0.1                 # equivalent
```

**Open local login.** For local-dev convenience there is no key and no password:
the `app` account has a blank password and sshd permits the empty-password
("none") method, so you connect with no prompt. The published port is bound to
**`127.0.0.1` only**, so the container is reachable from your machine but not
from the network. Root login is disabled.

> This is intentionally insecure and meant for a trusted local machine. If you
> later want key-only access, drop your public key into `home/.ssh/authorized_keys`
> and ask to re-enable `AuthenticationMethods publickey`.

## HTTPS credentials

When you `init` with an `http(s)` clone URL (e.g. a GitLab repo), nixenv prompts
for a username and Personal Access Token (input hidden) and stores them with
git's credential-store helper inside the project home:

```
~/.nixenv/projects/<name>/home/.git-credentials        https://user:token@host  (mode 600)
~/.nixenv/projects/<name>/home/.gitconfig.credentials  enables credential.helper = store
```

`.gitconfig` includes that file, so the token is reused for the clone and for
later `pull`/`push` inside the container. The token is stored in plaintext (as
git's `store` helper always does); the file is `chmod 600` and lives outside the
repo. SSH URLs skip this and use your keys instead. For non-interactive use,
export `GIT_HTTP_USER` / `GIT_HTTP_TOKEN`.

## Project layout

Projects always live under `~/.nixenv/projects/`. Each project has a host home
folder and a dedicated Docker volume for its code:

```
~/.nixenv/projects/<name>/home   → copied into /home/app  (.ssh, .zshrc, .gitconfig, configs)
docker volume <name>_app         → mounted at /app        (your code; the WORKDIR)
```

Each project also has a `port` file (its assigned SSH port) created on `init`.

A new project's `home/` is seeded from the embedded home skeleton. The runtime
container *copies* `home/` into `/home/app` so SSH key permissions can be
enforced (`700` dir, `600` files) regardless of how the host bind-mount exposes
ownership. Drop your SSH keys into `~/.nixenv/projects/<name>/home/.ssh/`.

Your code lives in the named volume `<name>_app` (not on the host). Populate it
by passing a git URL to `init` (cloned into the volume via a container), or by
cloning/working inside the container at `/app`. The volume persists across
container restarts.

Git identity is stored per project in `home/.gitconfig.identity`, which the
project's `.gitconfig` includes — so re-running `init` never duplicates the
`[user]` block.

## Toolchain

The shared profile includes git, zsh + oh-my-zsh + starship, OpenSSH, runit, the
Claude CLI (`claude`), common CLI tools (ripgrep, fd, fzf, bat, jq, delta,
lazygit, tmux, zellij, …), and language runtimes: Node 22 (with `npx`), Go, Rust
(rustup), PHP 8.5 + Composer, Python 3.12, and `uv` (with `uvx`). Edit the
embedded `flake.nix` block in `nixenv.sh` and re-run `build` to change the set.

### Shared Claude credentials

The Claude CLI keeps state in two places, and both are shared read-write so a
single `claude` login and config carry across all projects (and survive
container recreation):

```
~/.nixenv/claude        → /home/app/.claude        (credentials, settings, backups)
~/.nixenv/claude.json   → /home/app/.claude.json   (global config file)
```

Both are created automatically on first `run`. `~/.claude.json` lives in the
home root (not inside `.claude`), so it's shared as its own file; if it's ever
missing, the newest backup from the shared `.claude/backups/` is restored
automatically. (If you saw a "Claude configuration file not found" warning, it
was because only `.claude` was shared before — this resolves it.)

## Configuration

Override via environment variables:

- `CONTAINER_ENGINE` (`docker` or `podman`; auto-detects, asks if both present)
- `CONTEXT_DIR` (default `~/.nixenv/context`)
- `NIX_VOLUME` (default `nixos-store`)
- `BUILDER_IMAGE` (default `nixos/nix:2.32.8`)
- `RUNTIME_IMAGE` (default `debian:stable-slim`)
- `APP_USER` (default `app`)
- `INSTALL_DIR` / `INSTALL_NAME` (default `/usr/local/bin` / `nixenv`) — used by
  `install` / `uninstall`.
- `GIT_USER_NAME` / `GIT_USER_EMAIL` — skip the interactive git identity prompt.
- `GIT_HTTP_USER` / `GIT_HTTP_TOKEN` — skip the interactive HTTPS credentials
  prompt (for `init` with an `http(s)` URL).

Projects always live in `~/.nixenv/projects` (not configurable).

## Notes

- `~/.nixenv/projects/` holds SSH keys and per-project home state; the code
  itself lives in each project's `<name>_app` Docker volume.
- The Nix store volume persists across runs; `clean` is the only thing that
  removes it.
