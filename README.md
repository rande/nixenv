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

## Install

Three ways, all of which put `nixenv` on your `PATH`. Pick one.

### Homebrew (macOS and Linux)

```sh
brew install rande/nixenv/nixenv
nixenv --version
```

That taps `rande/homebrew-nixenv` and installs on first use; `brew upgrade
nixenv` afterwards. The formula has no dependencies — nixenv is a single bash
script that works with the system bash — so it installs in a second. You still
need a container engine, which Homebrew won't pull in for you:

```sh
brew install --cask docker        # or: brew install podman
brew install mkcert               # optional: trusted HTTPS for *.nixenv.localhost
```

Homebrew also installs this release's templates locally. To use those instead of
fetching from GitHub — pinning templates to the nixenv version you actually have:

```sh
export TEMPLATE_BASE="file://$(brew --prefix)/share/nixenv/templates"
```

Don't run `nixenv install` on a Homebrew install; it refuses, because a second
copy would never be upgraded by `brew`.

### Single file, no package manager

The script is self-contained, so one file is the whole tool:

```sh
curl -fsSLO https://github.com/rande/nixenv/releases/latest/download/nixenv.sh
chmod +x nixenv.sh && ./nixenv.sh --version
```

### From a clone

```sh
git clone https://github.com/rande/nixenv && cd nixenv
./nixenv.sh install              # copies to /usr/local/bin/nixenv
```

Override the location or name with `INSTALL_DIR` / `INSTALL_NAME`, and remove it
with `./nixenv.sh uninstall`. Once installed you can use `nixenv <command>`
instead of `./nixenv.sh <command>`. Note that the installed copy is a *snapshot*:
if you're editing `nixenv.sh`, keep calling `./nixenv.sh` from the clone or it
will be stale.

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
- `init <project> [git-url] [--build] [--unrestricted] [--allow=host,…] [--app-path=/path]` — scaffold the
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
- `restrict <project> [on|off]` / `allow <project> <host>…` /
  `egress <project> [-f]` — egress restriction to validated hosts only, ON by
  default (see [Egress restriction](#egress-restriction-default-validated-hosts-only)).
- `proxy [up|stop|status|logs|renew|remove-cert]` — shared HTTPS reverse proxy
  for all projects (see [Reverse proxy](#reverse-proxy-httpsproject-portnixenvlocalhost)).
- `up <project>` — build if needed, then start the service.
- `stop [<project>]` — stop and remove the project's service container; with no
  project, stops **every** nixenv container including the shared proxy (volumes
  and projects are untouched).
- `logs <project>` — follow the service container logs.
- `delete <project>` (alias `rm`) — permanently remove a project: its
  container(s), the app/home/databases volumes, and its host dir. Prints the
  exact commands it will run and asks for confirmation first.
- `sync-home <project>` — refresh the home volume's dotfiles from the embedded
  templates + per-project overrides (see [Updating dotfiles](#updating-dotfiles-sync-home)).
- `projects` — list projects with their SSH port and running state.
- `update` — refresh `flake.lock`, then rebuild into the volume.
- `status` — show context, volume, and shared-profile state.
- `gc [--dry-run]` — garbage-collect the store (see
  [Reclaiming disk space](#reclaiming-disk-space)).
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

## Templates — a ready-to-run stack in one command

```sh
./nixenv.sh init myblog   --template=wordpress    # WordPress + PHP + nginx + MariaDB
./nixenv.sh run  myblog                           # → https://myblog-8080.nixenv.localhost/

./nixenv.sh init myworker --template=cloudflare   # Cloudflare Workers + wrangler
./nixenv.sh run  myworker                         # → https://myworker-8787.nixenv.localhost/

./nixenv.sh init flows    --template=windmill     # Windmill self-hosted + PostgreSQL
./nixenv.sh run  flows                            # → https://flows-8000.nixenv.localhost/
```

Shipped templates: `wordpress`, `cloudflare`, `symfony`,
`headlesscms-directus-astro`, `windmill`.

**One file = one template**, and that file *becomes the project's `flake.nix`* —
so the result is an ordinary nixenv project you own and can edit, not a black
box. The template declares only the **toolchain** (php/nginx/mariadb/wp-cli, or
node/wrangler) plus config files and a startup hook. The application itself is
installed **once on first start** by that hook — `wp core download` +
`wp core install` + plugins for WordPress, a scaffolded Worker for Cloudflare —
so your site/worker is real editable files in the app volume that you can
git-commit. (A Nix build is sandboxed to its own `$out` and can never write the
app volume; the hook is the supported way to do runtime setup, and it's
marker-guarded so restarts are instant.)

Templates resolve three ways:

```sh
--template=wordpress                        # official, from the nixenv repo
--template=https://example.com/mystack.nix  # any URL
--template=./templates/wordpress.nix        # local file (your own fork)
```

Override the base for short names with `TEMPLATE_BASE`; fetched templates are
cached in `~/.nixenv/templates/`. A template can declare metadata that nixenv
reads *before* building — used to pre-fill the egress allowlist, the served port
and the app path:

```nix
# nixenv:description  WordPress + PHP 8.3 + nginx + MariaDB
# nixenv:port         8080
# nixenv:allow        wordpress.org api.wordpress.org downloads.wordpress.org
```

That `allow` line matters because projects are [egress-restricted by
default](#egress-restriction-default-validated-hosts-only) — it's what lets
WordPress fetch core and plugins on first run. Since a template is code that
gets built and whose hook runs in your container, `init` prints what it will do
and asks for confirmation (`--yes` to skip).

Writing your own: copy either file in [`templates/`](templates/), edit the
toolchain and the hook, and point `--template=` at it. The placeholders
`@@PROJECT@@`, `@@APP_MOUNT@@`, `@@DOMAIN@@` and `@@PORT@@` are substituted when
it's installed.

## Networking overview

Four distinct paths, each with its own knob. The diagram shows a restricted
project (the default); an unrestricted one differs only in that it sits on the
shared network and publishes its own ports.

```mermaid
flowchart LR
    subgraph HOST["🖥️  your Mac"]
        BROWSER["browser<br/>*.localhost → 127.0.0.1"]
        CLIENT["psql / TablePlus / ssh"]
    end

    subgraph PROXYC["📦 nixenv-proxy"]
        CADDY["Caddy :80/:443<br/><i>ingress — routes on Host</i>"]
        SQUID["squid :3128<br/><i>egress allowlist</i>"]
        RELAYS["socat relays<br/><i>ssh + declared ports</i>"]
    end

    subgraph PROJ["📦 nixenv-myapp &nbsp;(internal network)"]
        LOOP["socat 127.0.0.1:443/:80<br/><i>loopback relay</i>"]
        APP["your app :8000"]
        SSHD["sshd :2222"]
    end

    NET(["🌍 internet"])

    BROWSER -- "① https://myapp-8000.nixenv.localhost" --> CADDY
    CADDY -- "Host → container:port" --> APP
    APP -. "② public URL from inside<br/>curl forces *.localhost → 127.0.0.1" .-> LOOP
    LOOP -- "raw TCP, TLS stays end-to-end" --> CADDY
    APP -- "③ HTTPS_PROXY env → CONNECT" --> SQUID
    SQUID -- "allowed_hosts only<br/>else 403" --> NET
    CLIENT -- "④ 127.0.0.1:port" --> RELAYS
    RELAYS --> SSHD

    style NET fill:#eee,stroke:#999
```

| # | Path | Configure with |
| --- | --- | --- |
| ① | **Ingress** — browser → app, HTTPS, no setup | automatic; `proxy up\|status`, `PROXY_DOMAIN`, `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT`, mkcert for trusted certs |
| ② | **Public URL from inside** the container | automatic (loopback relay + CA injection); glibc clients need `nixenv host <p> <name>:127.0.0.1` |
| ③ | **Egress** to the internet — default-deny | `restrict <p> on\|off`, `allow <p> <host>`, `egress <p>` to see allowed vs denied |
| ④ | **Raw TCP** from your Mac (databases, ssh) | `expose <p> <port>`; ssh port is automatic |

Two paths need no proxy at all: **service-to-service** calls between projects
use `http://nixenv-<project>:<port>/` over the shared network, and anything
inside one container talks to itself on `localhost:<port>`.

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

### Reaching a public URL from *inside* a container

Public URLs work from inside containers too — `curl https://myapp-8000.nixenv.localhost/`
just works, no configuration:

```sh
./nixenv.sh shell myapp
curl https://myapp-8000.nixenv.localhost/     # → routed to the app, cert trusted
```

Three things make that work, all automatic:

**A loopback relay.** curl (and therefore libcurl, PHP's ext-curl, Guzzle,
Symfony HttpClient) implements RFC 6761 internally: it resolves `localhost` and
*any* `*.localhost` name to 127.0.0.1, **ignoring `/etc/hosts` and DNS**. So
rather than fight it, each project container runs a small `socat` relay
(supervised by runit) forwarding `127.0.0.1:443` and `:80` to the proxy — making
loopback genuinely correct. It's a raw TCP relay, so TLS stays end-to-end with
Caddy: SNI and the `Host` header arrive intact, the wildcard cert matches, and
routing works. Non-curl clients (PHP streams, Python, Go, Java) resolve via
`/etc/hosts`, so for those add one line pointing at loopback:

```sh
./nixenv.sh host myapp myapp-8000.nixenv.localhost:127.0.0.1
```

**Standard ports.** Caddy binds 80/443 *inside* the proxy container (it runs
with `net.ipv4.ip_unprivileged_port_start=0`), so URLs need no `:8443` suffix.

**Trusted TLS.** The proxy's root CA (mkcert's, or Caddy's internal one) is
mounted into every container and merged into a CA bundle exported as
`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`
and `GIT_SSL_CAINFO` — so HTTPS is *trusted*, not merely reachable.

For plain service-to-service calls you don't need any of this:
`http://nixenv-myapp:8000/` already resolves over the shared network and skips
the hairpin. Use the public URL when the app genuinely needs it — absolute link
generation, OAuth redirects, tests hitting the real hostname.

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

## Egress restriction (default): validated hosts only

Every project's **outbound** network is locked down **by default** to a
validated set of hosts — deny-everything-else. The forge domain from the clone
URL is validated automatically at `init`, so git keeps working out of the box:

```sh
./nixenv.sh init myapp https://gitlab.example.com/team/app.git
#   → gitlab.example.com auto-allowed; everything else denied
./nixenv.sh restrict myapp off        # opt OUT (full internet access)
./nixenv.sh restrict myapp on         # re-enable (the default)
./nixenv.sh init open-project --unrestricted   # opt out at creation
```

How it works: the restricted project runs on its own **internal** network — the
kernel gives it *no route to the internet at all* — and its only way out is a
**squid** allowlist proxy (default-deny) running inside the shared proxy
container. Enforcement is the missing route; squid is just policy, so nothing
in the container can bypass the list. `HTTP(S)_PROXY` is exported automatically
(npm, pip, composer, cargo, curl, git-https, the Claude CLI all honour it), and
ssh is routed through the proxy's CONNECT tunnel via a `ProxyCommand` added to
the container's `~/.ssh/config` — so `git@…` remotes to **validated** forges
keep working. SSH into the project and its declared ports keep working too
(they're relayed through the proxy container).

The allowlist lives at `~/.nixenv/projects/<name>/allowed_hosts`, one entry per
line. Matching is **exact** by default; prefix with a dot (or `*.`) to include
subdomains, and bare IPs are also accepted:

```
gitlab.example.com      # exactly this host
.yarnpkg.com          # yarnpkg.com AND every subdomain (classic.yarnpkg.com, …)
10.0.0.5              # a literal IP
```

`init` **seeds the forge domain from the clone URL automatically**, and
`--allow=` pre-validates anything else the project needs from the start
(comma-separated, repeatable):

```sh
./nixenv.sh init myapp https://gitlab.example.com/t/a.git \
    --allow=registry.npmjs.org,.yarnpkg.com --allow=pypi.org
```

Projects created before this feature have an empty list, so `allow` their forge
before pulling. Manage it from the host:

```sh
./nixenv.sh allow myapp registry.npmjs.org api.stripe.com   # add + reload
./nixenv.sh egress myapp                                    # allowed vs DENIED domains
./nixenv.sh egress myapp -f                                 # follow live
```

`egress` reads squid's access log, so the DENIED section is your worklist:
run the project, watch what gets blocked, `allow` what's legitimate. Limits to
know: UDP (QUIC) isn't proxied (tools fall back to TCP); DNS *resolution* still
works for any name (data can't flow, but lookups aren't blocked); proxy-less
raw-TCP clients can't reach external services (use ssh/CONNECT-capable paths);
and the CONNECT ports are limited to 443/22/80/9418.

### Allowlist cheatsheet (tools in the base toolchain + VS Code)

Copy the lines for the package managers your project actually uses (replace
`myapp`). All of these honour the proxy env automatically:

```sh
# git over HTTPS to GitHub (your own forge is seeded by init);
# release-assets serves GitHub Releases downloads
./nixenv.sh allow myapp github.com release-assets.githubusercontent.com

# npm / npx / pnpm
./nixenv.sh allow myapp registry.npmjs.org

# yarn
./nixenv.sh allow myapp registry.yarnpkg.com

# Composer (PHP) — packagist metadata + GitHub-hosted dists
./nixenv.sh allow myapp repo.packagist.org api.github.com codeload.github.com github.com

# pip / uv (Python)
./nixenv.sh allow myapp pypi.org files.pythonhosted.org

# cargo (Rust) — sparse index + crate downloads; rustup toolchains
./nixenv.sh allow myapp index.crates.io static.crates.io crates.io static.rust-lang.org

# go modules
./nixenv.sh allow myapp proxy.golang.org sum.golang.org

# Claude CLI (platform.claude.com serves OAuth login/token refresh)
./nixenv.sh allow myapp api.anthropic.com statsig.anthropic.com platform.claude.com

# Neovim / AstroNvim first launch (lazy.nvim clones plugins from GitHub)
./nixenv.sh allow myapp github.com

# VS Code Remote-SSH — server download + extension marketplace
./nixenv.sh allow myapp update.code.visualstudio.com vscode.download.prss.microsoft.com marketplace.visualstudio.com .vsassets.io
```

(VS Code alternative needing no allowlist: set
`"remote.SSH.localServerDownload": "always"` so your local VS Code uploads the
server over ssh.) For anything not listed, run the tool once and read the
DENIED section of `./nixenv.sh egress myapp` — it names the exact domains.

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
(local `/etc/hosts` entries, if any), `extra-parameters` (see below), and
`ssh/config`. Because the code and home are in volumes, they're not directly
editable from the host — you work through the container (`nixenv ssh` /
Remote-SSH / VS Code). Populate the code volume by passing a git URL to `init`,
or by cloning/working inside the container at the app mount (`/app` by default,
or your `--app-path`).

Git identity is stored per project in `home/.gitconfig.identity`, which the
project's `.gitconfig` includes — so re-running `init` never duplicates the
`[user]` block.

### Extra engine parameters

`init` and `run` create an empty `~/.nixenv/projects/<project>/extra-parameters`
for you. Anything you put there is appended **verbatim** to the container's
`run` — one flag per line, `#` comments allowed, no presets and no magic:

```
--memory=4g
--ulimit nofile=8192
```

There is no CLI flag for this on purpose; it's project state like `unrestricted`
or `ports`. Parameters apply when the container is **created**, so re-run
`./nixenv.sh run <project>` after editing. `run` echoes the active set.

#### Running podman/docker inside a project

That's what the commented example in the scaffolded file is for — uncomment it:

```
--security-opt seccomp=unconfined     # user-namespace syscalls (clone/unshare)
--security-opt apparmor=unconfined    # Debian/Ubuntu hosts
--security-opt label=disable          # SELinux hosts
--device /dev/fuse                    # fuse-overlayfs storage driver
--device /dev/net/tun                 # slirp4netns / pasta networking
```

Drop any `--device` your engine host doesn't have — a missing device makes `run`
fail outright. Two more caveats: podman isn't in the base toolchain (add it to
the project flake), and the container runs as your uid with no added
capabilities and no `/etc/subuid`/`/etc/subgid`, so rootless podman inside is
limited to a single UID — images that chown to other UIDs will fail unless the
project provides those mappings itself.


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
pkg-config, cmake, autoconf, automake, libtool), and an editor — **Neovim +
AstroNvim** (see [Editor](#editor-neovim--astronvim)).

The base ships **no language runtimes at all** — no Node, PHP, Python, Go, Rust,
Ruby — and no package managers or language servers for them. That's deliberate:
the base is the shell/editor/CLI toolbox every project shares, and languages
belong in a **per-project flake** (see
[Per-project tooling](#per-project-tooling)), so each project pins its own
versions and nothing pays for toolchains it never uses. Add the runtime and its
language server together:

```nix
paths = with pkgs; [
  nodejs_22                       # or php83 + php83Packages.composer
  typescript-language-server      # …and its LSP, so nvim works
];
```

The [templates](#templates--a-ready-to-run-stack-in-one-command) are complete
worked examples. Edit the embedded `flake.nix` block in `nixenv.sh` and re-run
`build` to change the base set.

## Editor (Neovim + AstroNvim)

`nvim` launches [AstroNvim](https://astronvim.com) — a Neovim distribution with a
VS Code-like feel: file tree, buffer tabs, statusline, LSP, completion, git
signs, and a VS Code colorscheme. Language servers come from the toolchain, not
Mason (which is disabled) — and since the base has no language runtimes, it
ships only the two servers that need none: `lua-language-server` (for editing
the nvim config itself) and `bash-language-server`, with their astrocommunity
packs enabled.

For a real language, add the server to the **project's** flake next to its
runtime (`pyright`, `intelephense`, `gopls`, `rust-analyzer`, `ruby-lsp`,
`typescript-language-server`, …) and enable the matching pack through a
per-project `<repo>/.nixenv/home/.config/nvim/` override applied with
[`sync-home`](#updating-dotfiles-sync-home).

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
automatically.

**Session transcripts are per-project**: while credentials/settings are shared,
`.claude/projects` is overlaid with a per-project directory, so every session's
JSONL transcript is reviewable on the host at

```
~/.nixenv/claude/projects/nixenv-<project>/<encoded-cwd>/<session-id>.jsonl
```

(without this, all projects using the same in-container path would interleave
their transcripts in one folder). Transcripts are auto-pruned after ~30 days;
raise `"cleanupPeriodDays"` in `~/.nixenv/claude/settings.json` to keep them. (If you saw a "Claude configuration file not found" warning, it
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
- `EGRESS_PORT` (default 3128) — squid's port inside the proxy container (not
  published; used by restricted projects).

Projects always live in `~/.nixenv/projects` (not configurable).

## Reclaiming disk space

The Nix store keeps every package it has ever built. Removing something from a
flake only makes those paths *unreachable* — it doesn't delete them, so the
store grows over time (a base rebuild that drops a language runtime can leave
gigabytes behind). Collect them:

```sh
./nixenv.sh gc --dry-run     # report what would go
./nixenv.sh gc               # delete it, prints before → after size
```

It deletes old profile generations plus every path not reachable from a live
profile — the base (`shared`) and each `proj-<project>` — then hardlinks
identical files. Everything your current toolchains reference is kept, so the
next `run` needs no downloads.

Stop your projects first if you want a full sweep: a **running** container
executes binaries from the store paths it started with, and if a rebuild has
since moved its profile forward, those older paths are collectable. `gc` warns
and asks before proceeding when it sees running containers, and reminds you to
restart them afterwards.

`gc` is the safe, incremental option; [`clean`](#commands) is the nuclear one —
it removes the whole volume, so the next `build` re-downloads everything.

## Testing

The test suite lives in `tests/` — **one bash file per test**, a shared
`tests/lib.sh` harness, and a runner. Exit codes: 0 pass, 77 skip, else fail.

```sh
./tests/run.sh                    # unit tests — pure logic, no docker needed
./tests/run.sh integration        # end-to-end against a real engine (DEDICATED env!)
./tests/run.sh all                # both
./tests/run-in-docker.sh          # the whole suite inside docker-in-docker —
                                  # touches nothing on your machine
NIXTEST_HEAVY=1 ./tests/run.sh integration   # include the slow flake-build test
```

Unit tests source `nixenv.sh` (functions only, nothing executes) and verify all
pure logic: URL/name/ACL parsing, Caddyfile/squid/start.sh generation, the
entrypoint's feature hooks, allowlist semantics. Integration tests exercise the
real flows — init/volumes/run/ssh/app-path/hosts/proxy routing/egress
deny+allow/sync-home/expose/delete — using an isolated prefix (`nxt-*`
containers, volumes, networks) and isolated state dirs; they sweep everything
prefixed before and after each test, and reuse the shared nix store volume
(test `00` builds it if missing). `run-in-docker.sh` wraps all of that in a
disposable privileged DinD container with a named cache volume
(`nixenv-dind-cache`) so repeat runs skip the store build.

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

## Version

```sh
./nixenv.sh --version        # nixenv 0.1.0
```

`--version` is dispatched before the embedded context is materialised, so it
needs no container engine, no network, and writes nothing — which is what makes
it usable as a packaging smoke test.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

nixenv is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.
