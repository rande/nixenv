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
   volume read-only at `/nix` and runs **entirely as your (non-root) host user**
   — `--user $(id -u):$(id -g)`. The login user `app` is supplied via a
   bind-mounted `/etc/passwd`, and an unprivileged `sshd` (on port 2222 inside
   the container) runs under the `runit` supervisor so you can SSH in. Nothing in
   the container runs as root. Nix binaries reference their own loader/libs by
   absolute `/nix` path, so the slim base's libc is irrelevant.

   Because the container runs as your user, `docker exec` / VS Code "Attach to
   Running Container" also land as `app`, not root.

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
- `build <project>` — build the project's **own** flake (from its repo) into a
  per-project profile, layered on the base (see
  [Per-project tooling](#per-project-tooling)).
- `init <project> [git-url] [--build]` — scaffold the project, prompt for git
  name/email, assign a stable random SSH port, and optionally clone `git-url`
  into the app volume. `--build` also builds the project's flake afterwards. For
  an `http(s)` URL it also prompts for a username + Personal Access Token and
  stores them (see [HTTPS credentials](#https-credentials)).
- `run <project>` — start the project as a background service (`sshd` under
  `runit`) and print its SSH port.
- `ssh <project>` — SSH into the running service (auto-starts it).
- `shell <project> [--session=NAME]` — interactive shell via `docker exec` (no
  SSH key needed); opens/attaches a named zellij session (see
  [Terminal sessions](#terminal-sessions)).
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
container runs an unprivileged `sshd` (supervised by `runit`, as your user) and
maps that host port to port **2222** inside the container.

```sh
./nixenv.sh ssh myapp                       # convenience wrapper
ssh -p <port> app@127.0.0.1                 # equivalent
```

**Open local login.** For local-dev convenience there is no key and no password:
the `app` account has an empty password (via the bind-mounted `/etc/shadow`) and
sshd permits the empty-password ("none") method, so you connect with no prompt.
The published port is bound to **`127.0.0.1` only**, so the container is
reachable from your machine but not
from the network. Root login is disabled.

> This is intentionally insecure and meant for a trusted local machine. If you
> later want key-only access, drop your public key into `home/.ssh/authorized_keys`
> and ask to re-enable `AuthenticationMethods publickey`.

## Terminal sessions

`ssh` and `shell` drop you into a **zellij** session by default, named after the
project. Because the session lives in the container, your panes/layout survive
disconnects — reconnecting with `nixenv ssh <project>` (or `shell`) re-attaches
the same session instead of starting fresh.

```sh
nixenv ssh myapp                     # attaches the "myapp" session (creates it once)
nixenv shell myapp --session=debug   # a second, independent session
nixenv ssh myapp --safe              # plain zsh, no zellij (if it's misbehaving)
```

`--session=NAME` opens/attaches a differently-named session; `--safe` skips
zellij entirely for that connection (equivalent to `NIXENV_NO_ZELLIJ=1`). Nesting
is prevented via an internal env var, so panes inside zellij never re-trigger it.

## Exposing ports

Each project publishes its SSH port automatically. To expose more (a dev server,
database, etc.), the easiest way is:

```sh
./nixenv.sh expose myapp 8080          # → 127.0.0.1:8080:8080
./nixenv.sh expose myapp 3000:3000     # host:container
./nixenv.sh expose myapp 0.0.0.0:80:80 # bind all interfaces (network-reachable)
```

Ports are stored one-per-line in `~/.nixenv/projects/<name>/ports`, so they
persist and you can also edit that file by hand. `expose` restarts the service
to apply them; otherwise they take effect on the next `run`. A bare number binds
to `127.0.0.1` (local only); pass a full `host:container` or
`address:host:container` spec for anything else.

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

Projects always live under `~/.nixenv/projects/`, all on the host:

```
~/.nixenv/projects/<name>/home   → bind-mounted at /home/app  (.ssh, .zshrc, .gitconfig, configs)
~/.nixenv/projects/<name>/repo   → bind-mounted at /app       (your code; the WORKDIR)
```

Each project also has a `port` file (its assigned SSH port) created on `init`,
and small generated `passwd`/`group`/`shadow` files (the container's user db).

A new project's `home/` is seeded from the embedded home skeleton. Both `home/`
and `repo/` are host bind-mounts owned by your uid, so the **non-root** container
can write to them directly — named volumes are root-owned and a non-root
container can't `chown` them, which is why these are host dirs. Drop your SSH
keys into `~/.nixenv/projects/<name>/home/.ssh/`, and put code in `repo/` (or
pass a git URL to `init` to clone it there).

Git identity is stored per project in `home/.gitconfig.identity`, which the
project's `.gitconfig` includes — so re-running `init` never duplicates the
`[user]` block.

## Per-project tooling

Beyond the shared base, a project can add its own dependencies via a `flake.nix`
**committed in its repo**. Build it with:

```sh
nixenv build myapp          # or: nixenv init myapp <git-url> --build
```

A ready-to-copy, heavily-commented starter lives at
[`templates/flake.nix`](templates/flake.nix) — drop it into a project repo as
`flake.nix` and edit the `paths` list.

The repo flake must expose `packages.<system>.default` (override the attribute
with `PROJECT_ATTR`), typically a `buildEnv` of the extra tools:

```nix
# flake.nix in your project repo
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";   # match the base to share the store
  outputs = { self, nixpkgs }:
    let pkgs = import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
    in { packages.x86_64-linux.default = pkgs.buildEnv {
           name = "myapp-deps";
           paths = with pkgs; [ nodejs_24 postgresql_16 awscli2 terraform ];
         }; };
}
```

`build <project>` extracts `flake.nix` (+ `flake.lock`) from the app volume and
installs it into a per-project profile (`/nix/var/nix/profiles/proj-<name>`) in
the **same** store, so packages already present (from the base or another
project) aren't rebuilt. At runtime that profile goes on `PATH` **ahead** of the
base, so the project sees base ∪ its extras (and can shadow a base tool with a
pinned version). Rebuild after changing the repo flake; `delete` removes the
profile too.

Limitation: only the flake files are extracted, so a repo flake that references
*other* local files in the repo (relative paths, or building the repo itself)
won't build this way — keep the project flake to declaring dependencies.

## Toolchain

The shared profile includes git, zsh + oh-my-zsh + starship, OpenSSH, runit, the
Claude CLI (`claude`), common CLI tools (ripgrep, fd, fzf, bat, jq, delta,
lazygit, tmux, zellij, …), a build toolchain (gnumake, gcc, binutils,
pkg-config, cmake, autoconf, automake, libtool), and language runtimes: Node 22
(with `npx`), Go, Rust (rustup), PHP 8.5 + Composer, Python 3.12, and `uv` (with
`uvx`). Edit the embedded `flake.nix` block in `nixenv.sh` and re-run `build` to
change the set.

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

- `~/.nixenv/projects/<name>/` holds SSH keys, per-project home state, and the
  code (`repo/`) — all on the host, owned by your uid.
- The Nix store volume persists across runs; `clean` is the only thing that
  removes it.
