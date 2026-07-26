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
2. **Standalone volume.** A named Docker volume (`nixenv__nixos_store`) holds `/nix`.
3. **Builder container.** A short-lived `nixos/nix` container realises every
   dependency from the flake into the volume and installs them into a shared
   profile (`/nix/var/nix/profiles/shared`) that also lives in the volume.
4. **Runtime container.** A lightweight `debian:stable-slim` container mounts the
   store read-only at `/nix` and runs **entirely as your (non-root) host user**
   — `--user $(id -u):$(id -g)`, hostname set to the project name. The login user
   `app` is supplied via a bind-mounted `/etc/passwd`, code and home come from
   per-project named volumes (chown'd to your uid), and an unprivileged `sshd`
   (port 2222) runs under the `runit` supervisor so you can SSH in. Nothing in
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
./nixenv.sh run myapp             # start the service (prints the SSH port;
                                  # also auto-starts the shared HTTPS proxy)
./nixenv.sh ssh myapp             # SSH in as 'app'
```

With the app listening on `:3000`, it's already reachable at
`https://myapp-3000.nixenv.localhost/` (see
[Reverse proxy](#reverse-proxy-httpsproject-portnixenvlocalhost)).

Clone a repo while initialising (cloned into the project's app volume), and
optionally pick where it mounts in the container:

```sh
./nixenv.sh init myapp git@github.com:me/app.git
./nixenv.sh init web  git@github.com:me/web.git --app-path=/var/www/html
```

Don't want to set up keys? `./nixenv.sh shell myapp` drops you straight into an
interactive `zsh` via `docker exec` (no SSH key needed).

## Commands

- `build` — (re)write context, then download all flake deps into the volume.
- `build <project> [--dir=<path>]` — build the project's **own** flake into a
  per-project profile, layered on the base. Default reads `flake.nix` from the
  repo root; `--dir=<path>` copies a whole folder (flake + local files it
  references). See [Per-project tooling](#per-project-tooling).
- `init <project> [git-url] [--build] [--app-path=/path]` — scaffold the
  project, prompt for git name/email, assign a stable random SSH port, and
  optionally clone `git-url` into the app volume. `--build` also builds the
  project's flake afterwards. `--app-path=/path` mounts the code volume at a
  custom container path instead of `/app` (e.g. `/var/www/myapp`, to match
  production); it's stored in `<project>/app_mount` and used by `run`, `shell`,
  and the login `cd`. For an `http(s)` URL it also prompts for a username +
  Personal Access Token and stores them (see
  [HTTPS credentials](#https-credentials)).
- `run <project>` — start the project as a background service (`sshd` under
  `runit`) and print its SSH port.
- `ssh <project>` — SSH into the running service (auto-starts it). For
  persistent zmx sessions, use `ssh <project>` via your `~/.ssh/config` (see
  [Terminal sessions](#terminal-sessions-zmx-via-ssh-project)).
- `shell <project>` — interactive zsh via `docker exec` (no SSH key needed).
- `ssh-config [--install]` — wire `ssh <project>` into your `~/.ssh/config`.
- `expose <project> <port>…` — publish extra port(s) (see
  [Exposing ports](#exposing-ports)).
- `host <project> <name:ip>…` — add custom `/etc/hosts` entries (see
  [Custom /etc/hosts](#custom-etchosts)).
- `proxy [up|stop|status|logs|renew|remove-cert]` — shared HTTPS reverse proxy
  for all projects (see [Reverse proxy](#reverse-proxy-httpsproject-portnixenvlocalhost)).
- `up <project>` — build if needed, then start the service.
- `stop <project>` — stop and remove the project's service container.
- `logs <project>` — follow the service container logs.
- `delete <project>` (alias `rm`) — permanently remove a project: its
  container(s), the app/home/databases volumes, and its host dir. Prints the
  exact commands it will run and asks for confirmation first.
- `sync-home <project>` — refresh the home volume's dotfiles from the embedded
  templates + per-project overrides (see [Updating dotfiles](#updating-dotfiles-sync-home)).
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

## Terminal sessions (zmx) via `ssh <project>`

Each project gets a generated **host** ssh config at
`~/.nixenv/projects/<name>/ssh/config`. Add one Include line to your
`~/.ssh/config` and you can `ssh <project>` directly:

```sh
nixenv ssh-config --install     # adds: Include ~/.nixenv/projects/*/ssh/config
ssh myapp                       # persistent zmx session 'myapp'
ssh myapp.api                   # a second session 'myapp.api'
```

The generated config uses [`zmx`](https://github.com/neurosnap/zmx) (bundled in
the base toolchain) for re-attachable terminal sessions over ssh, with
`ControlMaster` multiplexing — the same pattern zmx documents. The session name
comes from the ssh host, so `ssh myapp` / `ssh myapp.api` give you distinct,
persistent sessions you can detach from and re-attach later. Edit the per-project
file freely (it's only created when missing); swap the `RemoteCommand` for a
plain shell if you prefer.

`nixenv ssh <project>` and `nixenv shell <project>` connect directly (plain zsh,
no zmx) — handy as an escape hatch. The prompt shows the project name (the
container's hostname is set to it), plus the zmx session when you're in one.

## Exposing ports

> **Tip — for HTTP(S) services, prefer the
> [Reverse proxy](#reverse-proxy-httpsproject-portnixenvlocalhost).** Any port
> your app listens on is already reachable at
> `https://<project>-<port>.nixenv.localhost/` with zero configuration — no
> `expose`, no restart, no host-port conflicts between projects, and you get
> HTTPS. `expose` is mainly for **non-HTTP** traffic (a database client on your
> Mac, a raw TCP service) or when a tool needs a plain `127.0.0.1:<port>`.

Each project publishes its SSH port automatically. To expose more directly (a
database, raw TCP, etc.):

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

## Reverse proxy (`https://<project>-<port>.nixenv.localhost/`)

A single shared **Caddy** container (run from the Nix store — no extra image)
routes pretty HTTPS URLs to any project by parsing the hostname:

```
https://<project>-<port>.nixenv.localhost/  →  container nixenv-<project>, port <port>
e.g. https://myapp-3000.nixenv.localhost/   →  your dev server on :3000
```

Every project container automatically joins a shared network (`nixenv_net`) on
`run`, and the proxy **auto-starts with the first project** (disable with
`PROXY_AUTOSTART=0`), so usually there's nothing to do. Manage it explicitly
with `./nixenv.sh proxy up | stop | status | logs`. New projects need no proxy
configuration — the routing is dynamic. Your app must listen on `0.0.0.0` (not
`127.0.0.1`) inside its container so the proxy can reach it.

`*.localhost` resolves to `127.0.0.1` automatically in Chrome and Firefox;
Safari needs an `/etc/hosts` line. The proxy sends the standard forwarded
headers (`X-Forwarded-Proto: https`, `X-Forwarded-For/-Host/-Port`,
`X-Real-IP`), so frameworks behind a trusted proxy generate correct `https://`
URLs. Host ports default to 80/443 (`PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT`; use
8080/8443 for rootless Podman, which can't bind below 1024).

### Trusted certificates (mkcert)

Out of the box the proxy uses Caddy's internal CA, so browsers show a warning.
If [`mkcert`](https://github.com/FiloSottile/mkcert) is installed, an explicit
`proxy up` issues a trusted wildcard cert for `*.nixenv.localhost` instead:

```sh
brew install mkcert nss     # nss = Firefox trust
./nixenv.sh proxy up        # issues the wildcard cert (one-time 'mkcert -install')
```

The one-time `mkcert -install` adds mkcert's local CA to your OS/browser trust
stores and may ask for your password — the script **explains exactly what it
does before running it**, and only runs it when the CA isn't already installed.
Prefer manual control? Run `mkcert -install` yourself first, or skip trusting
entirely with `PROXY_MKCERT_INSTALL=0` (HTTPS still works, with a warning). The
auto-start on `run` never runs `mkcert -install`, so it can never surprise you
with a prompt. `proxy renew` reissues the cert; `proxy remove-cert` deletes
nixenv's cert (falling back to the internal CA) without touching mkcert's CA.

## Custom /etc/hosts

The container's `/etc/hosts` is rebuilt by the entrypoint on every start from
base entries plus two optional sources, in order:

1. **Declared in the project flake** (versioned, team-shared): ship an
   `etc/hosts.extra` in the project profile via
   `pkgs.writeTextDir "etc/hosts.extra" ''…''` added to `buildEnv.paths` — see
   [`templates/flake.nix`](templates/flake.nix). Apply with
   `nixenv build <project>` + restart.
2. **Host-side, local-only**: `~/.nixenv/projects/<name>/hosts.extra`, native
   `/etc/hosts` format (`ip<TAB>name`). Edit it by hand, or append entries with:

```sh
./nixenv.sh host myapp db:10.0.0.5 api.local:127.0.0.1
```

Entries apply on the next container start (`host` restarts a running project
for you). This is file-driven rather than `--add-host` so it's declarative,
idempotent, and works with the non-root container.

## Updating dotfiles (`sync-home`)

The home volume is seeded from the skeleton **once**, so template updates (a new
git default, an AstroNvim pin, …) don't propagate to existing projects on their
own. Refresh them with:

```sh
./nixenv.sh sync-home myapp
```

This layers the embedded skeleton first, then per-project overrides committed in
the repo at `<repo>/.nixenv/home/` (mirroring `$HOME` paths — e.g.
`.nixenv/home/.config/nvim/lua/plugins/extra.lua`), which win over the skeleton.
Every file it overwrites is backed up inside the volume at
`~/.nixenv/home-backups/<timestamp>`, and it never touches installed nvim
plugins, shell history, or your git identity/credentials.

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

Each project's code and home live in **named Docker volumes**:

```
volume nixenv_<name>_app        → /app          (your code; the WORKDIR — customisable
                                                 via init --app-path=/path)
volume nixenv_<name>_home       → /home/<user>  (.ssh, .zshrc, .gitconfig, configs)
volume nixenv_<name>_databases  → /databases    (persistent DB data: pgsql, redis, …)
```

`/databases` is an empty, writable, per-project volume for database *data files*.
Point your services at it — e.g. Postgres `PGDATA=/databases/pgsql`, Redis
`dir /databases/redis` — so the data survives container recreation (run the DBs
themselves as runit startup services — `<repo>/.nixenv/sv/<name>/run`, documented
in [`templates/flake.nix`](templates/flake.nix) — or by hand).

The volumes are created and **chown'd to your uid** (via a one-time throwaway
root helper container) so the non-root runtime container can write them — that's
the trick that lets us use fast named volumes while staying non-root. On macOS
Docker Desktop this is much faster than host bind-mounts for heavy file I/O
(`node_modules`, installs, git).

Host-side, `~/.nixenv/projects/<name>/` keeps only small state: `home/` (the
**seed** the home volume is populated from on first run — skeleton + git config),
the generated `passwd`/`group`/`shadow` (the container's user db), `port`,
`ports`, `app_mount` (custom code-volume path, if set), `hosts.extra`
(local `/etc/hosts` entries, if any), and `ssh/config`. Because the code and home are in volumes, they're not directly
editable from the host — you work through the container (`nixenv ssh` /
Remote-SSH / VS Code). Populate the code volume by passing a git URL to `init`,
or by cloning/working inside the container at the app mount (`/app` by default,
or your `--app-path`).

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

By default only `flake.nix` (+ `flake.lock`) is copied, so a flake that
references *other* local files won't resolve. For that case, put the flake and
its local files in a folder and point at it:

```sh
nixenv build myapp --dir=nix        # copies the whole repo/nix/ folder
nixenv build myapp --dir=/abs/path  # or an absolute host path
```

`--dir` copies the entire folder into the build, so relative references inside it
(overlays, a vendored package, `./.`-style local inputs) work.

## Toolchain

The shared profile includes git, zsh + oh-my-zsh + starship, OpenSSH, runit,
Caddy (for the shared reverse proxy), the
Claude CLI (`claude`), zmx (terminal session persistence), common CLI tools
(curl, wget, ping, host/dig, ripgrep,
fd, fzf, bat, jq, delta, lazygit, …), a build toolchain (gnumake, gcc, binutils,
pkg-config, cmake, autoconf, automake, libtool), language runtimes: Node 22
(with `npx`), Go, Rust (rustup), PHP 8.5 + Composer, Python 3.12, and `uv` (with
`uvx`), and an editor — **Neovim + AstroNvim** with language servers for Go,
TypeScript/JavaScript, Python, Rust, PHP, Ruby, Bash, and Lua (see
[Editor](#editor-neovim--astronvim)). Edit the embedded `flake.nix` block in
`nixenv.sh` and re-run `build` to change the set.

## Editor (Neovim + AstroNvim)

`nvim` launches [AstroNvim](https://astronvim.com) — a Neovim distribution with a
VS Code-like feel: file tree, buffer tabs, statusline, LSP, completion, git
signs, and a VS Code colorscheme. Language servers come from the base toolchain
(`gopls`, `rust-analyzer`, `pyright`, `typescript-language-server`,
`intelephense`, `ruby-lsp`, `bash-language-server`, `lua-language-server`), so
they're on `PATH` and Mason won't download its own copies.

The config lives at `~/.config/nvim/init.lua` (seeded from the skeleton, editable
in the home volume). On the **first** `nvim` launch, `lazy.nvim` downloads the
plugins (needs network; a one-time step that persists in the home volume). For
the icons to render, use a **Nerd Font** in your terminal.

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
- `NIX_VOLUME` (default `nixenv__nixos_store`)
- `BUILDER_IMAGE` (default `nixos/nix:2.32.8`)
- `RUNTIME_IMAGE` (default `debian:stable-slim`)
- `APP_USER` (default `app`)
- `INSTALL_DIR` / `INSTALL_NAME` (default `/usr/local/bin` / `nixenv`) — used by
  `install` / `uninstall`.
- `GIT_USER_NAME` / `GIT_USER_EMAIL` — skip the interactive git identity prompt.
- `GIT_HTTP_USER` / `GIT_HTTP_TOKEN` — skip the interactive HTTPS credentials
  prompt (for `init` with an `http(s)` URL).
- `APP_MOUNT` — default code-volume mount path for `init` (same as
  `--app-path`).
- `PROXY_DOMAIN` (default `nixenv.localhost`), `PROXY_NET` (default
  `nixenv_net`), `PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT` (default 80/443; use
  8080/8443 for rootless Podman), `PROXY_AUTOSTART` (default 1; 0 = don't start
  the proxy on `run`), `PROXY_MKCERT_INSTALL` (0 = never run `mkcert -install`).

Projects always live in `~/.nixenv/projects` (not configurable).

## Notes

- Code, home, and databases live in named volumes and survive `stop`/`run` and
  rebuilds; only `delete <project>` (with confirmation) and `clean` remove data.
  `~/.nixenv/projects/<name>/` on the host holds only small state (home seed,
  SSH config, git credentials, port).
- The Nix store volume persists across runs; `clean` is the only thing that
  removes it.
- The `.gitconfig` seeded into each home ships sensible modern defaults
  (histogram diff, `push.autoSetupRemote`, `rerere`, `rebase.autoStash`, …),
  largely from [how Git core devs configure Git](https://blog.gitbutler.com/how-git-core-devs-configure-git#tldr).
