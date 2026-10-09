# nixenv

A self-contained shell tool for spinning up disposable, per-project development
containers that share one common set of tools through a single Nix store.

Instead of baking every tool into a Docker image, `nixenv.sh` downloads all
dependencies once into a standalone Docker volume (the Nix store) and lets each
project container mount that store read-only. Containers start instantly and
every project shares the same pinned toolchain.

> Contributing? [DEVELOPING.md](DEVELOPING.md) covers the local setup, the
> tests, and developing nixenv from inside a nixenv project.

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

### GitHub token (optional, recommended on shared networks)

Nix looks up nixpkgs through GitHub's API, which allows only **60 anonymous
requests per hour per IP address**. On a shared address (an office network, a
VPN, CI) everyone behind it shares those 60, so `nixenv build` or `update` can
fail with `API rate limit exceeded`. A token raises the limit to 5,000/hour.

The first `build` or `update` without one explains this and asks for a token —
press Enter to skip, and it won't ask again. The link it prints opens GitHub's
token page already filled in: a fine-grained token named `nixenv` with **no
permissions**, which means read-only access to public repositories, all Nix
needs. Manage it any time:

```sh
nixenv github-token            # set or replace it
nixenv github-token --status
nixenv github-token --clear
GITHUB_TOKEN=$(gh auth token) nixenv update   # or pass one for a single run
```

It's stored in `~/.nixenv/github_token` (mode 600) and only given to nixenv's
own toolchain builds — never to a project's flake. If a build does hit the limit,
or the token has expired, nixenv says so under the error.

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

Homebrew also installs this release's templates locally, and nixenv uses them
automatically, so templates always match the nixenv version you have.

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

> Every example below uses `nixenv`. Working from a clone without installing?
> Substitute `./nixenv.sh` — the commands are otherwise identical.

## Quick start

```sh
nixenv build                 # download all deps into the volume (slow once)
nixenv init myapp            # scaffold a project, prompts for git identity
nixenv start myapp             # start the service (prints the SSH port;
                                  # also auto-starts the shared HTTPS proxy)
nixenv ssh myapp             # SSH in as 'app'
```

With the app listening on `:3000`, it's already reachable at
`https://myapp-3000.nixenv.localhost/` (see
[Reverse proxy](#reverse-proxy-httpsproject-portnixenvlocalhost)).

Clone a repo while initialising (cloned into the project's app volume),
optionally pick the branch, and where it mounts in the container:

```sh
nixenv init myapp git@github.com:me/app.git
nixenv init myapp git@github.com:me/app.git --branch=develop   # a branch or tag, not the default one
nixenv init web  git@github.com:me/web.git --app-path=/var/www/html
```

Don't want to set up keys? `nixenv shell myapp` drops you straight into an
interactive `zsh` via `docker exec` (no SSH key needed).

## Commands

- `build` — (re)write context, then download all flake deps into the volume.
- `build <project> [--dir=<path>]` — build the project's **own** flake into a
  per-project profile, layered on the base. Default reads `flake.nix` from the
  repo root; `--dir=<path>` copies a whole folder (flake + local files it
  references) and is **remembered**, so later rebuilds are just
  `nixenv build <project>`. `--dir=` (empty) forgets it. See
  [Per-project tooling](#per-project-tooling).
- `init <project> [git-url] [--build] [--unrestricted] [--allow=host,…] [--app-path=/path]` — scaffold the
  project, prompt for git name/email, assign a stable random SSH port, and
  optionally clone `git-url` into the app volume. `--build` also builds the
  project's flake afterwards. `--app-path=/path` mounts the code volume at a
  custom container path instead of `/app` (e.g. `/var/www/myapp`, to match
  production); it's stored in `<project>/app_mount` and used by `start`, `shell`,
  and the login `cd`. For an `http(s)` URL it also prompts for a username +
  Personal Access Token and stores them (see
  [HTTPS credentials](#https-credentials)).
- `start <project> [-v]` (alias `run`) — start the project as a background service (`sshd` under
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
- `capture <project> [on|off|untrust|web|log -f|tui|har <file>|clear]` — record a
  restricted project's HTTP(S) traffic with mitmproxy, with a web UI and CLI
  views (see [Capturing traffic](#capturing-traffic-capture)).
- `deploy <project> [--agent=<socket>|--no-agent] [-- <command>…]` — open a shell
  in a **throwaway** container with your ssh agent forwarded, the shared code,
  your git credentials and an extended egress allowlist; `deploy <project> allow|hosts|log|stop` manage it
  (see [Deploying](#deploying-deploy)).
- `proxy [up|reload|stop|status|logs [egress]|renew|remove-cert]` — shared HTTPS
  reverse proxy for all projects, plus the egress container restricted projects
  go out through (see [Reverse proxy](#reverse-proxy-httpsproject-portnixenvlocalhost)).
- `up <project>` — build if needed, then start the service.
- `stop [<project>]` — stop and remove the project's service container; with no
  project, stops **every** nixenv container including the shared proxy (volumes
  and projects are untouched).
- `logs <project>` — follow the service container logs.
- `delete <project>` (alias `rm`) — permanently remove a project: its
  container(s), the app/home/databases volumes (and the deploy state volume, if
  any), and its host dir. Prints the
  exact commands it will run and asks for confirmation first.
- `sync-home <project>` — refresh the home volume's dotfiles from the embedded
  templates + per-project overrides (see [Updating dotfiles](#updating-dotfiles-sync-home)).
- `projects` — list projects with their SSH port and running state.
- `ps [--json] [--watch [N]]` — what runs where: the ports each project's
  processes actually listen on, with their proxy URLs, plus services and egress
  settings. Also refreshes the dashboard at `https://nixenv.localhost/` (see
  [Project dashboard](#project-dashboard-nixenv-ps)).
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
nixenv ssh myapp                       # convenience wrapper
ssh -p <port> -i ~/.nixenv/projects/myapp/ssh/id_ed25519 app@127.0.0.1   # equivalent
```

**Key-only login, with no setup.** The first `start` generates an ed25519 key for
the project on your machine, in `~/.nixenv/projects/<name>/ssh/id_ed25519`, and
wires it into both `nixenv ssh` and the generated `~/.ssh` config — so
`ssh <project>`, zmx and VS Code Remote-SSH connect with no prompt, as before.
The container's sshd accepts **only** that key: passwords are off, and the key
list is a read-only file mounted from your machine, so nothing inside a
container can authorise a key of its own.

That matters because sshd is reachable from more than your machine. Projects on
the shared network can reach each other, and restricted projects can reach each
other through the proxy's relays — with an open login, any project could get a
shell in any other. The published port is still bound to **`127.0.0.1` only**,
and root login is disabled.

To use your own key as well (say, one already loaded in your agent), add it to
`~/.nixenv/projects/<name>/ssh/authorized_keys.extra`, one per line. It's picked
up on the next `start`, without a restart if the container is already up.

The key never leaves your machine: it isn't part of an `export`, so an imported
project gets a new one.

**The container is verified, too.** Its sshd host key is also generated on your
machine and pinned in `~/.nixenv/projects/<name>/ssh/known_hosts` (under the
alias `nixenv-<name>`, not the port). `ssh <project>` and `nixenv ssh` check it
strictly, so if something else grabs the project's port while its container is
stopped, ssh refuses to connect instead of handing your session to it.
Hand-written ssh commands need `-o HostKeyAlias=nixenv-<name> -o
UserKnownHostsFile=~/.nixenv/projects/<name>/ssh/known_hosts`, or use the
generated config.

> A container started before these changes still runs the old sshd (and, for
> host-key pinning, the old host key, so `ssh` reports a changed key).
> `nixenv start <name>` warns about it; `nixenv stop <name> && nixenv start <name>`
> applies the fix.

## Terminal sessions (zmx) via `ssh <project>`

Each project gets a generated **host** ssh config at
`~/.nixenv/projects/<name>/ssh/config`. Add one Include line to your
`~/.ssh/config` and you can `ssh <project>` directly:

```sh
nixenv ssh-config --install     # adds: Include ~/.nixenv/projects/*/ssh/config
ssh myapp                       # plain shell (ssh myapp <cmd> runs a command)
ssh myapp.main                  # persistent zmx session 'myapp.main'
ssh myapp.api                   # a second session 'myapp.api'
```

The generated config uses [`zmx`](https://github.com/neurosnap/zmx) (bundled in
the base toolchain) for re-attachable terminal sessions over ssh, with
`ControlMaster` multiplexing — the same pattern zmx documents. The session name
comes from the ssh host, so `ssh myapp.main` / `ssh myapp.api` give you
distinct, persistent sessions you can detach from and re-attach later. The
shared `Host myapp myapp.*` block sets no `RemoteCommand`, so the bare
`ssh myapp` is a plain shell, the name to use for `ssh myapp <cmd>`, scp, rsync
and VS Code Remote-SSH. Only the `Host myapp.*` block after it adds
`RequestTTY yes` and the zmx `RemoteCommand` (ssh keeps the first value it finds
for each option). Keep the names exact: `Host myapp*` would also match another
project such as `myapp-api`. Edit the per-project file freely (it's only
created when missing).

A config written by an older nixenv (zmx inside the `Host myapp myapp.*` block)
is not changed. Move its `RequestTTY yes` and `RemoteCommand` lines into a new
`Host myapp.*` block at the end, or delete
`~/.nixenv/projects/myapp/ssh/config` and `nixenv start myapp` writes the new
one.

`nixenv ssh <project>` and `nixenv shell <project>` connect directly (plain zsh,
no zmx), like `ssh <project>`. The prompt shows the project name (the
container's hostname is set to it), plus the zmx session when you're in one.

## Templates — a ready-to-run stack in one command

```sh
nixenv init myblog   --template=wordpress    # WordPress + PHP + nginx + MariaDB
nixenv start  myblog                           # → https://myblog-8080.nixenv.localhost/

nixenv init myworker --template=cloudflare   # Cloudflare Workers + wrangler
nixenv start  myworker                         # → https://myworker-8787.nixenv.localhost/

nixenv init flows    --template=windmill     # Windmill self-hosted + PostgreSQL
nixenv start  flows                            # → https://flows-8000.nixenv.localhost/
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

Short names are pinned to the templates that shipped with your nixenv: the
`templates/` folder next to the script (a clone, or Homebrew's copy), otherwise
the GitHub tag matching `nixenv --version` — never the moving `main` branch.
Override with `TEMPLATE_BASE` (e.g. `…/rande/nixenv/main/templates` to follow
`main`). Plain `http://` templates are refused, since a template is code
(`NIXENV_ALLOW_INSECURE_TEMPLATES=1` overrides). Fetched templates are cached in
`~/.nixenv/templates/`, and their sha256 is printed. A template can declare metadata that nixenv
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

    subgraph PROXYC["📦 nixenv__proxy"]
        CADDY["Caddy :80/:443<br/><i>ingress — routes on Host</i>"]
        RELAYS["socat relays<br/><i>ssh + declared ports</i>"]
    end

    subgraph EGRESSC["📦 nixenv__egress"]
        SQUID["squid :3128<br/><i>egress allowlist</i>"]
        MITM["mitmproxy<br/><i>only with 'capture'</i>"]
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
    SQUID -. "captured projects" .-> MITM
    MITM -.-> NET
    CLIENT -- "④ 127.0.0.1:port" --> RELAYS
    RELAYS --> SSHD

    style NET fill:#eee,stroke:#999
```

| # | Path | Configure with |
| --- | --- | --- |
| ① | **Ingress** — browser → app, HTTPS, no setup | automatic; `proxy up\|status`, `PROXY_DOMAIN`, `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT`, mkcert for trusted certs |
| ② | **Public URL from inside** the container | automatic (loopback relay + CA injection); glibc clients need `nixenv host <p> <name>:127.0.0.1` |
| ③ | **Egress** to the internet — default-deny | `restrict <p> on\|off`, `allow <p> <host>`, `egress <p>` to see allowed vs denied, `capture <p> on` to record it |
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
nixenv expose myapp 8080          # → 127.0.0.1:8080:8080
nixenv expose myapp 3000:3000     # host:container
nixenv expose myapp 0.0.0.0:80:80 # bind all interfaces (network-reachable)
```

Ports are stored one-per-line in `~/.nixenv/projects/<name>/ports`, so they
persist and you can also edit that file by hand. `expose` restarts the service
to apply them; otherwise they take effect on the next `start`. A bare number binds
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
`start`, and the proxy **auto-starts with the first project** (disable with
`PROXY_AUTOSTART=0`), so usually there's nothing to do. Manage it explicitly
with `nixenv proxy up | reload | stop | status | logs`. New projects need no proxy
configuration — the routing is dynamic. Your app must listen on `0.0.0.0` (not
`127.0.0.1`) inside its container so the proxy can reach it.

`*.localhost` resolves to `127.0.0.1` automatically in Chrome and Firefox;
Safari needs an `/etc/hosts` line — or use the **nip.io** form, a real DNS
name that resolves to `127.0.0.1` everywhere:

```
https://<project>-<port>-127.0.0.1.nip.io/   →  same route as <project>-<port>.nixenv.localhost
e.g. https://myapp-3000-127.0.0.1.nip.io/
```

It is on by default (`PROXY_NIP_DOMAIN=127.0.0.1.nip.io`; set it empty to turn
it off, or to another wildcard-DNS name such as `10.0.0.5.sslip.io`). It relies
on the public nip.io resolver: the names you open are sent to it, and some
routers drop DNS answers that point at `127.0.0.1` (DNS rebinding protection).
Restricted projects have no outside DNS, so from inside them use the
`.nixenv.localhost` form. After upgrading, run `nixenv proxy up` once so an
mkcert certificate covers the new name.

#### From your other devices (Tailscale)

The proxy listens on `127.0.0.1` only. To reach your projects from another
device on your tailnet, publish it on your Tailscale address too and point
the nip.io names at it:

```sh
# every nixenv command must see the same values: keep them in ~/.nixenv/config
ip="$(tailscale ip -4)"                                # e.g. 100.101.102.103
printf 'PROXY_BIND=%s\nPROXY_NIP_DOMAIN=%s.nip.io\n' "$ip" "$ip" >> ~/.nixenv/config
nixenv proxy up        # recreates the proxy with the new address and cert
# → https://myapp-3000-100.101.102.103.nip.io/ from any device on the tailnet
```

`PROXY_BIND` takes IPv4 addresses (several, space- or comma-separated);
`127.0.0.1` is always kept, so the local URLs keep working. `0.0.0.0` publishes
on every interface, your LAN included. **Everything served by the proxy is then
reachable from that network**: every project's web ports and the dashboard.
Project ssh ports stay on loopback. Other devices must trust the proxy's CA to avoid
certificate warnings: install `~/.nixenv/proxy/certs/rootCA.pem` (mkcert's or
Caddy's root) on them. If the address is missing when the proxy starts (e.g.
Tailscale is down), the engine refuses to publish on it and the proxy doesn't
start. The proxy sends the standard forwarded
headers (`X-Forwarded-Proto: https`, `X-Forwarded-For/-Host/-Port`,
`X-Real-IP`), so frameworks behind a trusted proxy generate correct `https://`
URLs. Host ports default to 80/443 (`PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT`; use
8080/8443 for rootless Podman, which can't bind below 1024).

### Reaching a public URL from *inside* a container

Public URLs work from inside containers too — `curl https://myapp-8000.nixenv.localhost/`
just works, no configuration:

```sh
nixenv shell myapp
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
nixenv host myapp myapp-8000.nixenv.localhost:127.0.0.1
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

### Projects can't reach each other by default

A **restricted** project (the default) can reach only its *own* public URLs
through the proxy: from `myapp`, `https://other-8000.nixenv.localhost/` returns
`403`. That stops one compromised project from driving another's admin UI. Your
browser on the host is never affected. To let projects talk, list the callers in
the **target's** `accept-from` file and reload the proxy (no restart):

```sh
echo myapp >> ~/.nixenv/projects/other/accept-from   # '*' = every project
nixenv proxy reload
```

Unrestricted projects share one flat network and can reach each other directly
(`http://nixenv-other:8000/`), so this guard doesn't apply to them.

### Project dashboard (`nixenv ps`)

nixenv only knows the ports you *declare*. `nixenv ps` asks each running
container which ports its processes **actually listen on**: it reads
`/proc/net/tcp` through `docker exec`/`podman exec`, from the host. It prints
them with their proxy URLs:

```sh
nixenv ps
# shop                   running  restricted  ssh 2201
#       8080  nginx  https://shop-8080.nixenv.localhost/
#       5432  postgres  (127.0.0.1 only — not reachable through the proxy)
#       services: nginx:run php-fpm:run worker:down
#       denied: api.stripe.com×4   (allow: nixenv allow shop <host>)
#       ! service 'worker' is down — check: nixenv logs shop
```

The same scan is published as a page at **`https://nixenv.localhost/`**, served
by the shared proxy. Each project gets one full-width card. On the left are
its open ports as links, its services, any warnings and, while capture is on,
a link to its mitmweb UI. The UI still asks for its token: get the full URL
from `nixenv capture <project> web`. On the right is the
*Survey*, always shown: allowlist, `ssh_hosts`, `accept-from`, capture,
declared ports, the ssh port and the extra engine parameters. Values passed
with `-e`/`--env` are shown as `NAME=…`, never their content. Hosts squid
refused are listed by `nixenv ps` and `nixenv egress <project>`. A *Help*
section below the projects lists every command with its options and an
example. The page uses the same paper/blueprint design as the project site.

- **When it updates:** `ps`, `start`, `stop`, `proxy up` and `proxy reload` rewrite
  it. Services take a while to start listening after `start`, so `start` also
  re-checks after 10 s, 30 s and 90 s (change the delays with
  `NIXENV_DASHBOARD_DELAYS="5 20 120"`, or turn this off with
  `NIXENV_DASHBOARD_DELAYS=`). A project that started recently and has no open
  port yet shows as *starting*. The page re-reads the data every 5 s, so
  `nixenv ps --watch` (every 5 s, or `--watch 30`) keeps it live.
  `nixenv ps --json` prints the same data for scripts.
- **Who can see it:** your browser, and unrestricted projects (they share a
  network anyway). Restricted projects get a `403`. The page holds no secrets:
  no tokens, no credentials, environment values from `extra-parameters`
  redacted, and deploy hosts only as a count. It is read-only,
  with no buttons that change anything.
- **An older proxy** doesn't have the page's files mounted yet. Run
  `nixenv proxy up` once; `ps` and `proxy reload` remind you until you do.
- **Ports bound to `127.0.0.1`** are shown but not linked: the proxy is another
  container and can't reach them. Bind dev servers to `0.0.0.0`.

### Trusted certificates (mkcert)

Out of the box the proxy uses Caddy's internal CA, so browsers show a warning.
If [`mkcert`](https://github.com/FiloSottile/mkcert) is installed, an explicit
`proxy up` issues a trusted wildcard cert for `*.nixenv.localhost` instead:

```sh
brew install mkcert nss     # nss = Firefox trust
nixenv proxy up        # issues the wildcard cert (one-time 'mkcert -install')
```

The one-time `mkcert -install` adds mkcert's local CA to your OS/browser trust
stores and may ask for your password — the script **explains exactly what it
does before running it**, and only runs it when the CA isn't already installed.
Prefer manual control? Run `mkcert -install` yourself first, or skip trusting
entirely with `PROXY_MKCERT_INSTALL=0` (HTTPS still works, with a warning). The
auto-start on `start` never runs `mkcert -install`, so it can never surprise you
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
nixenv host myapp db:10.0.0.5 api.local:127.0.0.1
```

Entries apply on the next container start (`host` restarts a running project
for you). This is file-driven rather than `--add-host` so it's declarative,
idempotent, and works with the non-root container.

## Egress restriction (default): validated hosts only

Every project's **outbound** network is locked down **by default** to a
validated set of hosts — deny-everything-else. The forge domain from the clone
URL is validated automatically at `init`, so git keeps working out of the box:

```sh
nixenv init myapp https://gitlab.example.com/team/app.git
#   → gitlab.example.com auto-allowed; everything else denied
nixenv restrict myapp off        # opt OUT (full internet access)
nixenv restrict myapp on         # re-enable (the default)
nixenv init open-project --unrestricted   # opt out at creation
```

How it works: the restricted project runs on its own **internal** network — the
kernel gives it *no route to the internet at all* — and its only way out is a
**squid** allowlist proxy (default-deny) running in the shared `nixenv__egress`
container. Enforcement is the missing route; squid is just policy, so nothing
in the container can bypass the list. (squid used to run inside the proxy
next to Caddy; it has its own container now, so restarting the reverse proxy
no longer cuts every project off the network. A project container created
before that still points at the old address — `start` tells you, and
`nixenv stop <p> && nixenv start <p>` fixes it.) `HTTP(S)_PROXY` is exported automatically
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
203.0.113.7           # requests addressed to this IP literally
```

An IP entry matches requests *addressed* to that IP, not hostnames that happen
to resolve to it — honouring the latter would mean looking up every requested
name, which is exactly the leak described below. Private, loopback and
link-local addresses are always refused, whatever the allowlist says.

`init` **seeds the forge domain from the clone URL automatically**, and
`--allow=` pre-validates anything else the project needs from the start
(comma-separated, repeatable):

```sh
nixenv init myapp https://gitlab.example.com/t/a.git \
    --allow=registry.npmjs.org,.yarnpkg.com --allow=pypi.org
```

Projects created before this feature have an empty list, so `allow` their forge
before pulling. Manage it from the host:

```sh
nixenv allow myapp registry.npmjs.org api.stripe.com   # add + reload
nixenv egress myapp                                    # allowed vs DENIED domains
nixenv egress myapp -f                                 # follow live
```

`egress` reads squid's access log, so the DENIED section is your worklist:
run the project, watch what gets blocked, `allow` what's legitimate. Limits to
know: UDP (QUIC) isn't proxied (tools fall back to TCP); proxy-less raw-TCP
clients can't reach external services (use ssh/CONNECT-capable paths); and the
CONNECT ports are limited to 443/22/80.

**Port 22 only to your git host.** `init` writes the forge's hostname to
`~/.nixenv/projects/<name>/ssh_hosts`, and only the hosts listed there can be
reached on port 22 (git over ssh). Add a line per extra git host, then
`nixenv proxy reload`. Projects created before this have no such file and keep
the old behaviour, where every allowed host is reachable on 22.

### What egress restriction does not protect against

It is a *hostname* allowlist, so it stops code from reaching hosts you didn't
allow. It can't judge what happens with the hosts you did allow:

- **An allowed forge is a way out.** With `github.com` allowed (the default for
  a GitHub clone), code can push to *any* repository or gist, not just yours.
- **Wildcards are wide.** `.githubusercontent.com` or `.vsassets.io` cover huge
  namespaces, parts of which other people control.
- **Shared CDNs can front other sites.** An allowed CDN hostname can be used to
  reach other customers of the same CDN (domain fronting).
- **Port 22 reaches any sshd on an allowed name**, unless `ssh_hosts` narrows it
  (see above).
- **UDP and QUIC aren't proxied** — they just fail, so this isn't a leak, but
  tools must fall back to TCP.

`nixenv egress <project>` flags wildcard and forge entries in its summary, so
you can review them.

**Refused names are never looked up.** A DNS lookup is itself a way out: code
that asks for `<secret>.attacker.example` delivers the secret to whoever runs
that domain's nameserver, even though the request is then refused. So the proxy
decides on the *name* first, and only resolves names that are already allowed —
it still does that, to refuse an allowed name that points at a private address.

## Capturing traffic (`capture`)

See exactly what a project sends and receives — every HTTP(S) request, headers
and bodies — with [mitmproxy](https://mitmproxy.org), in a web UI or from the
terminal:

```sh
nixenv capture myapp on            # egress + ingress (or: on egress | on ingress)
nixenv capture myapp web           # prints the UI URL: https://myapp-mitm.nixenv.localhost/?token=…
nixenv capture myapp log -f        # one line per request, live
nixenv capture myapp tui           # the recorded flows in mitmproxy's console UI
nixenv capture myapp har out.har   # export for browser devtools & co
nixenv capture myapp off           # stop recording (files kept)
nixenv capture myapp clear         # delete the recordings
```

- **Egress** — the project's outbound requests. mitmproxy sits *behind* squid,
  so the allowlist still decides first: a refused host gets its 403 and never
  reaches mitmproxy (or its DNS). HTTPS is decrypted, which only works because
  the container trusts mitmproxy's CA — after the FIRST `capture on` the
  project must restart once (`capture on` offers to do it). It then keeps
  trusting the CA across `capture off`, so later captures need no restart (and
  don't kill a running shell or Claude session); `nixenv capture myapp untrust`
  plus a restart revokes it. Apps that pin
  certificates will refuse the connection; that shows as `TLS-REFUSED` in the
  log. ssh and `git://` are never captured.
- **Ingress** — requests to the project's public URLs
  (`https://<project>-<port>.nixenv.localhost/`), routed by Caddy through
  mitmproxy on the way in. The app still sees the public `Host`.

Only **restricted** projects (the default) can be captured: an unrestricted
one talks to the internet directly, with no proxy in the path.

**Captures are secrets.** They hold whatever crossed the wire: tokens,
cookies, the `Authorization` header of an HTTPS `git fetch`. They are stored
owner-only in `~/.nixenv/proxy/egress-data/captures/<project>.{flows,log}`,
`delete` removes them, and the UI is served by the proxy as
`https://<project>-mitm.nixenv.localhost/` (no extra host port), behind a
password (the `token` in the URL — don't paste it around). The token is
required, but only once per browser: the first visit sets a login cookie
(400 days), after which plain `https://<project>-mitm.nixenv.localhost/` opens
it. One mitmweb shows every captured project; the printed URL opens it
pre-filtered to `<project>` (`#/flows?s=~comment <project>`). With
`PROXY_HTTPS_PORT` other than 443, the URL includes that port. No
restricted project can open the UI, not even the one being captured, and no project can reach
mitmproxy directly: its listeners are bound to the egress container's
loopback (only squid uses them) or to the network it shares with Caddy alone.
Capture fails closed: if mitmproxy is down, the captured project's requests
fail rather than go out unrecorded (`nixenv proxy logs egress` shows why).
mitmproxy keeps flows in memory for the UI; `capture <p> clear` (or `off`)
restarts it.

### Allowlist cheatsheet (tools in the base toolchain + VS Code)

Copy the lines for the package managers your project actually uses (replace
`myapp`). All of these honour the proxy env automatically:

```sh
# git over HTTPS to GitHub (your own forge is seeded by init);
# release-assets serves GitHub Releases downloads
nixenv allow myapp github.com release-assets.githubusercontent.com

# npm / npx / pnpm
nixenv allow myapp registry.npmjs.org

# yarn
nixenv allow myapp registry.yarnpkg.com

# Composer (PHP) — packagist metadata + GitHub-hosted dists
nixenv allow myapp repo.packagist.org api.github.com codeload.github.com github.com

# pip / uv (Python)
nixenv allow myapp pypi.org files.pythonhosted.org

# cargo (Rust) — sparse index + crate downloads; rustup toolchains
nixenv allow myapp index.crates.io static.crates.io crates.io static.rust-lang.org

# go modules
nixenv allow myapp proxy.golang.org sum.golang.org

# Claude CLI (platform.claude.com serves OAuth login/token refresh)
nixenv allow myapp api.anthropic.com statsig.anthropic.com platform.claude.com

# Neovim / AstroNvim first launch (lazy.nvim clones plugins from GitHub)
nixenv allow myapp github.com

# VS Code Remote-SSH — server download + extension marketplace
nixenv allow myapp update.code.visualstudio.com vscode.download.prss.microsoft.com marketplace.visualstudio.com .vsassets.io
```

(VS Code alternative needing no allowlist: set
`"remote.SSH.localServerDownload": "always"` so your local VS Code uploads the
server over ssh.) For anything not listed, run the tool once and read the
DENIED section of `nixenv egress myapp` — it names the exact domains.

## Deploying (`deploy`)

Your ssh agent should never be forwarded into the dev
container: everything running there — dependencies, scripts, an AI agent — runs
as the same user and could use it. `nixenv deploy <project>` gives you a
separate, throwaway container for that, which can still edit the code, commit
and push (e.g. a `release.sh` that bumps a version):

```sh
nixenv deploy myapp allow 5.196.77.220 51.255.65.147     # deploy-only hosts
nixenv deploy myapp --agent=~/.ssh/deploy-agent.sock      # shell; exit = gone
nixenv deploy myapp -- ./release.sh 1.2.0                 # or one command
```

| | dev container (`start`) | deploy container (`deploy`) |
|---|---|---|
| code (app volume) | read-write | read-write (the **same** volume) |
| home | the home volume | **tmpfs**, rebuilt from the skeleton |
| persistent state | home + databases volumes | **`/deploy`**: the deploy state volume |
| git identity | home volume | the host seed's (written by `init`) |
| git https credentials | home volume | **the dev container's** (its `~/.git-credentials`), seed as fallback |
| tools | base + project profile | the same (base includes `age`, `sops`) |
| egress | `allowed_hosts` | `allowed_hosts` **+** `deploy_hosts` |
| your ssh agent | never | forwarded for the session |
| lifetime | until `stop` | removed when you exit |

**State.** Everything in the deploy home is gone when you exit. What must
survive between sessions — terraform or ansible state, release bookkeeping —
goes in `/deploy` (`$NIXENV_DEPLOY_STATE`), the volume `nixenv_<project>_deploy`.
The first `deploy` creates it; later sessions reuse it. It is never mounted in
the dev container, so code running there can neither read it nor plant files in
it. `delete` removes it, and `export` includes it when it exists. Your deploy
shell history is kept there too (`/deploy/.zsh_history`).

**Allowlist.** The deploy container can reach everything the dev container can,
plus `~/.nixenv/projects/<project>/deploy_hosts` (`deploy … allow`). Put
production there and **not** in `allowed_hosts`, and the dev container can't
reach it at all. Deploy egress is switched on by that file existing (`deploy
allow` creates it; `touch` it to give deploy just the dev allowlist). Without
it the deploy container has no network.

**Host-side files** (in `~/.nixenv/projects/<project>/`, none writable from the
dev container):
- `home/.gitconfig.identity` — your git identity, written by `init`.
- `home/.git-credentials` — the token `init` stored. Only a fallback: deploy
  pushes with the **dev container's** `~/.git-credentials` (read from its home
  volume as plain data), so a token you changed there is the one used. Nothing
  else from the dev home volume is read.
- `deploy_gitconfig` — included by the deploy `.gitconfig`, e.g. to push an
  https remote over ssh with the agent:
  `[url "git@github.com:"] pushInsteadOf = https://github.com/`.
- `deploy_ssh_config` — included by the deploy `~/.ssh/config` (server aliases, users).
- `deploy_known_hosts` — persists across sessions; first contact is
  trust-on-first-use, a changed key is refused.

**How it connects:** the container's sshd listens on **loopback only**, and the
host reaches it with `ProxyCommand <engine> exec -i … socat`, so there is no
published port or relay, and the agent rides the ssh session. That works the
same on Docker Desktop, Linux and podman. The session uses the project's key and
pinned host key.
The session connects to the host name `nixenv-deploy-<project>`, so your
`~/.ssh/config` can choose the agent for every deploy:

```
Host nixenv-deploy-*
    IdentityAgent ~/.ssh/deploy-agent.sock
```

The agent ssh would use (`IdentityAgent`, else `$SSH_AUTH_SOCK`) is forwarded,
unless your config sets `ForwardAgent` itself. `--agent=<socket>` forwards a
specific one and `--no-agent` none (`NIXENV_DEPLOY_AGENT` changes the default).
Your config can't change how the session connects: the transport, key,
host-key check and the no-`ControlMaster` rule are fixed on the command line,
which ssh gives precedence.

**What it does not protect against:** the code is shared with the dev
container, which can change it at any moment. A script you run in the deploy
container runs with your agent. The deploy shell neutralises the git settings
that would run a program on ordinary commands (`core.fsmonitor`, hooks,
`core.sshCommand`), but a modified `release.sh` or `Makefile` is a different
matter. Review what you run. An agent that asks before each use
lets you notice an unexpected signature.

The `deploy_*` files travel in an export; on import, `deploy_hosts` is
re-validated and the config files are applied only after you confirm them.

## Updating dotfiles (`sync-home`)

The home volume is seeded from the skeleton **once**, so template updates (a new
git default, an AstroNvim pin, …) don't propagate to existing projects on their
own. Refresh them with:

```sh
nixenv sync-home myapp
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
volume nixenv_<name>_deploy     → /deploy       (deploy container only; created by
                                                 the first `deploy`)
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
(local `/etc/hosts` entries, if any), `extra-parameters` (see below),
`capture` (present while [`capture`](#capturing-traffic-capture) is on),
`deploy_hosts`/`deploy_ssh_config`/`deploy_gitconfig`/`deploy_known_hosts` (for
[`deploy`](#deploying-deploy)), and
`ssh/config`. Recorded traffic lives outside it, in
`~/.nixenv/proxy/egress-data/captures/<name>.{flows,log}`. Because the code and home are in volumes, they're not directly
editable from the host — you work through the container (`nixenv ssh` /
Remote-SSH / VS Code). Populate the code volume by passing a git URL to `init`,
or by cloning/working inside the container at the app mount (`/app` by default,
or your `--app-path`).

Git identity is stored per project in `home/.gitconfig.identity`, which the
project's `.gitconfig` includes — so re-running `init` never duplicates the
`[user]` block.

### Extra engine parameters

`init` and `start` create an empty `~/.nixenv/projects/<project>/extra-parameters`
for you. Anything you put there is appended **verbatim** to the container's
`start` — one flag per line, `#` comments allowed, no presets and no magic:

```
--memory=4g
--ulimit nofile=8192
```

There is no CLI flag for this on purpose; it's project state like `unrestricted`
or `ports`. Parameters apply when the container is **created**, so re-run
`nixenv start <project>` after editing. `start -v` echoes the active set.

Every project container (and the proxy) starts hardened: `--cap-drop=ALL`,
`--security-opt=no-new-privileges` and `--pids-limit=4096` (change it with
`NIXENV_PIDS_LIMIT`; `0` removes it, which rootless podman without cgroup
delegation needs). Your extra parameters come **after** these, so a
`--cap-add=…` or `--security-opt=no-new-privileges=false` there wins — each one
loosens the sandbox, so add only what you need. There's no default memory limit;
add `--memory=4g` here if you want one.

#### Running podman/docker inside a project

That's what the commented example in the scaffolded file is for — uncomment it:

```
--security-opt seccomp=unconfined     # user-namespace syscalls (clone/unshare)
--security-opt apparmor=unconfined    # Debian/Ubuntu hosts
--security-opt label=disable          # SELinux hosts
--device /dev/fuse                    # fuse-overlayfs storage driver
--device /dev/net/tun                 # slirp4netns / pasta networking
```

Drop any `--device` your engine host doesn't have — a missing device makes `start`
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

**Only build flakes you trust.** Building a flake runs its build code as root,
with write access to the Nix store that *every* project shares. nixenv limits
what a project flake can do: its `nixConfig` is ignored (so it can't add its own
binary cache and signing key), `GITHUB_TOKEN` is not passed to it, and builds
are sandboxed when the builder can create namespaces. The builder container
usually can't, and then Nix builds without a sandbox. So a malicious flake can
still tamper with the shared store and, through it, other projects. `build`
reminds you of this the first time you build each project. A template's flake,
and any repo you `init … --build`, falls under the same rule.

## Toolchain

The shared profile includes git, zsh + oh-my-zsh + starship, OpenSSH, runit,
Caddy (for the shared reverse proxy), `age` and `sops` (encrypted secrets), the
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

### Claude: one login, separate settings per project

You log in to `claude` once and every project uses that login. Everything else
Claude keeps — settings, hooks, MCP servers, `CLAUDE.md`, slash commands — is
**per project**, so one project can't plant something that runs in another:

```
~/.nixenv/claude/.credentials.json          → shared by all projects (the login)
~/.nixenv/claude/profiles/<project>/        → that project's ~/.claude + ~/.claude.json
~/.nixenv/claude/projects/nixenv-<project>/ → that project's session transcripts
```

**What a project can still read:** the login token itself. Token refresh
rewrites the credentials file, so it has to be shared read-write, and any code
running in a project (a cloned repo's startup hook included) can read it. Only
run `claude` in containers holding code you trust, or log in per project by
deleting the shared file and logging in inside each one.

New project profiles start empty (no settings are copied from anywhere). If you
used nixenv before this change, your old shared config is still at
`~/.nixenv/claude.json` and `~/.nixenv/claude/settings.json`; copy what you want
into a project's profile by hand — and check it for `mcpServers` or `hooks`
entries you don't recognise first. `delete <project>` removes its profile but
keeps its transcripts.

Transcripts are reviewable on the host at
`~/.nixenv/claude/projects/nixenv-<project>/<encoded-cwd>/<session-id>.jsonl`
and are auto-pruned after ~30 days; raise `"cleanupPeriodDays"` in the project's
`profiles/<project>/dot-claude/settings.json` to keep them.

## Configuration

The proxy settings (`PROXY_DOMAIN`, `PROXY_NIP_DOMAIN`, `PROXY_BIND`,
`PROXY_HTTP_PORT`, `PROXY_HTTPS_PORT`, `PROXY_AUTOSTART`,
`PROXY_MKCERT_INSTALL`) can be kept in **`~/.nixenv/config`**, one `KEY=VALUE`
per line, so every command sees them without exporting anything:

```sh
# ~/.nixenv/config
PROXY_BIND=100.101.102.103
PROXY_NIP_DOMAIN=100.101.102.103.nip.io
```

The file is read, never executed; other keys are ignored with a warning, and
an environment variable still overrides it for one command. `nixenv --help`
shows the values in effect.

Everything below can be overridden via environment variables:

- `CONTAINER_ENGINE` (`docker` or `podman`; auto-detects, asks if both present)
- `CONTEXT_DIR` (default `~/.nixenv/context`)
- `CONTAINER_PREFIX` (default `nixenv`) — every engine-side name: containers
  `<prefix>-<project>`, volumes `<prefix>_<project>_*`, and the defaults of
  `NIX_VOLUME` and `PROXY_NET` below. Two prefixes on one engine share nothing.
- `NIX_VOLUME` (default `<prefix>__nixos_store`, i.e. `nixenv__nixos_store`)
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
- `PROXY_DOMAIN` (default `nixenv.localhost`), `PROXY_NIP_DOMAIN` (default
  `127.0.0.1.nip.io`; empty = no `<project>-<port>-127.0.0.1.nip.io` route),
  `PROXY_BIND` (extra host IPv4 addresses for the proxy's 80/443, e.g. your
  Tailscale IP; `127.0.0.1` is always kept), `PROXY_NET` (default
  `<prefix>_net`, i.e. `nixenv_net`), `PROXY_HTTP_PORT` / `PROXY_HTTPS_PORT` (default 80/443; use
  8080/8443 for rootless Podman), `PROXY_AUTOSTART` (default 1; 0 = don't start
  the proxy on `start`), `PROXY_MKCERT_INSTALL` (0 = never run `mkcert -install`).
- `EGRESS_PORT` (default 3128) — squid's port inside the `nixenv__egress`
  container (not published; used by restricted projects).
- `NIXENV_DASHBOARD_DELAYS` (default `10 30 90`) — seconds after `start` at which
  the [dashboard](#project-dashboard-nixenv-ps) is re-checked; empty = off.

Projects always live in `~/.nixenv/projects` (not configurable).

## Backup and migrate (`export` / `import`)

Move a whole project to another machine, or keep a backup:

```sh
nixenv stop myapp                     # a live database tars inconsistently
nixenv export myapp                   # → nixenv-myapp-20260927-101500.tar
# ...copy it across...
nixenv import nixenv-myapp-20260927-101500.tar
nixenv build myapp && nixenv start myapp
```

`import <file> <new-name>` clones a project under a different name on the same
machine — handy for forking a database-heavy environment. Importing onto a name
that already exists needs `--force`, which **replaces that project's volumes** —
it warns and asks first (`--yes` to skip the prompt).

**What travels by default:** the `app` and `databases` volumes, the `deploy`
state volume if [`deploy`](#deploying-deploy) has created one, plus everything
in `~/.nixenv/projects/<project>/` that isn't regenerated per machine — egress
and deploy settings, ports, hosts, extra engine parameters, your extra
authorized ssh keys, and the home seed with its git identity. Git credentials in
the seed travel only with `--with-home`. If your deploy tools keep secrets in
`/deploy` (terraform state often does), `export` warns that the archive holds
them; `import` restores that volume only into `/deploy` of the deploy container.

**An archive may be someone else's, so `import` checks what it restores.** Host
lists and ports are re-validated (ports stay on loopback), the git identity is
rebuilt from name and email only, and anything that changes how the container is
created or who can log in — `extra-parameters`, `unrestricted`, the deploy ssh/git
configs and known hosts, extra authorized keys — is shown and applied only after
you answer yes. Without a terminal, or if you say no, those files are kept next
to their target as `<file>.imported` for you to review and rename.

**A token in the repo's `.git/config` is the other leak.** If you ever cloned
with `https://user:token@host/…`, git stored that URL verbatim — and the app
volume is in every archive. `export` refuses when it finds one and tells you how
to fix the remote; `import` strips any it finds. Only `http(s)` URLs are touched
(`ssh://git@host` is a username, not a secret).

**The home volume is opt-in.** It holds `~/.ssh` and `~/.git-credentials`, so
including it by default would make every backup a credential leak. A default
archive is safe to hand to a colleague; `import` builds a fresh home instead —
the archived seed's dotfiles and git identity (skeleton for anything missing),
and `.ssh/` at mode 700.

```sh
nixenv export myapp --with-home       # keeps shell history, nvim plugins,
                                      # ~/.local/bin — and the secrets. ⚠️
```

Without `--with-home` you lose shell history, installed nvim plugins and
anything you dropped in `~/.local/bin`; everything else in that volume is
reseeded. After such an import, to restore outbound git auth:

If the project clones over HTTPS, `import` notices and prompts for a username
and token itself. For git-over-ssh you still need a key:

```sh
nixenv ssh myapp && ssh-keygen -t ed25519
```

**What never travels, and why:**

- **The shared Nix store.** Gigabytes, and fully reproducible — that's what
  `nixenv build` is for. An archive is the size of your data, not your toolchain.
- **`passwd`/`group`/`shadow`.** Generated from your uid. `import` regenerates
  them and **chowns the restored volumes to your uid**, which is what makes a
  cross-machine move work at all — the archive's files carry the *exporting*
  machine's ownership.
- **The SSH port.** `import` assigns a fresh free one and prints it; the exported
  port may already be taken here.
- **The project's ssh key, host key and ssh config.** Re-created on import, so
  an archive you receive can't come with a key someone else holds. The host
  ssh config embeds this machine's port and paths.
- **Capture state** (`capture`, `capture-trust`): whether this machine's
  mitmproxy CA is trusted is a local decision.

`export` refuses while the project is running, because copying a live Postgres or
MySQL data directory is crash-consistent at best. `--force` overrides it with a
warning, which is fine for a code-only project and not fine for a database.
It also refuses while a `deploy` session is open, for the same reason.

Both commands report progress as they go, so a multi-GB volume doesn't look like a
hang:

```
==> Archiving nixenv_myapp_databases
   archiving databases… 48312 files
   databases.tar.gz  1.4G
```

On a terminal that's a single self-updating line. Piped or in CI it prints a line
periodically instead, so logs stay readable. `NIXENV_PROGRESS=0` turns it off.

## Reclaiming disk space

The Nix store keeps every package it has ever built. Removing something from a
flake only makes those paths *unreachable* — it doesn't delete them, so the
store grows over time (a base rebuild that drops a language runtime can leave
gigabytes behind). Collect them:

```sh
nixenv gc --dry-run     # report what would go
nixenv gc               # delete it, prints before → after size
```

It deletes old profile generations plus every path not reachable from a live
profile — the base (`shared`) and each `proj-<project>` — then hardlinks
identical files. Everything your current toolchains reference is kept, so the
next `start` needs no downloads.

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
pure logic: URL/name/ACL parsing, Caddyfile/squid/start.sh/egress.sh
generation, the entrypoint's feature hooks, allowlist semantics, and the
capture addon (against a stub mitmproxy, so no install is needed). Integration
tests exercise the real flows — init/volumes/run/ssh/app-path/hosts/proxy
routing/egress deny+allow/capture/sync-home/expose/delete — using an isolated prefix (`nxt-*`
containers, volumes, networks) and isolated state dirs; they sweep everything
prefixed before and after each test, and reuse the shared nix store volume
(test `00` builds it if missing). `run-in-docker.sh` wraps all of that in a
disposable privileged DinD container with a named cache volume
(`nixenv-dind-cache`) so repeat runs skip the store build.

## FAQ

**Which ports is my project actually serving, and at what URL?**
Run `nixenv ps`, or open `https://nixenv.localhost/`. See
[Project dashboard](#project-dashboard-nixenv-ps).

**Can two projects talk to each other? Do I add the other one to `allowed_hosts`?**
No: `allowed_hosts` is for the outside world. A restricted project has no route
to other containers, and squid refuses any name that resolves to a private
address, so `nixenv-other` in `allowed_hosts` is still denied. Instead, the
**target** grants access in its `accept-from`, and the caller uses the target's
public URL (`https://other-8000.nixenv.localhost/`):

```sh
echo myapp >> ~/.nixenv/projects/other/accept-from   # '*' = every project
nixenv proxy reload                                  # no restart needed
```

The target decides, so a compromised caller can't grant itself access. Unrestricted
projects share one network and reach each other directly (`http://nixenv-other:8000/`).
See [Projects can't reach each other by default](#projects-cant-reach-each-other-by-default).

**How do I reach a service on my host (`host.docker.internal`)? `--add-host` in `extra-parameters` does nothing.**
`extra-parameters` is passed to the engine verbatim, but `--add-host` has no
effect: nixenv mounts its own `/etc/hosts` and the entrypoint rebuilds it on
every start (see [Custom /etc/hosts](#custom-etchosts)). The same applies to
podman's automatic `host.containers.internal`.

- From a **restricted** project you can't reach the host:
  `host.docker.internal` resolves to a private address, which squid always
  refuses. Even when the name is in `allowed_hosts`, the request shows up as
  `TCP_DENIED` in `nixenv egress <project>`.
- From an **unrestricted** project on Docker Desktop, it already works:
  Docker's DNS resolves the name.
- From an **unrestricted** project on Linux, map the name to the gateway of
  the project network with `nixenv host`. The host service must listen on that
  address or on `0.0.0.0`.

```sh
nixenv restrict myapp off
gw="$(docker network inspect nixenv_net -f '{{(index .IPAM.Config 0).Gateway}}')"
nixenv host myapp "host.docker.internal:$gw"
nixenv stop myapp && nixenv start myapp
```

Use `extra-parameters` for flags the engine applies itself (`--memory`,
`--ulimit`, `--device`, …). It is read only when the container is **created**,
so after an edit run `stop` and then `start`: `start` on a running container keeps
the old flags.

## Notes

- Code, home, and databases live in named volumes and survive `stop`/`start` and
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
nixenv --version        # nixenv 0.1.0
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
