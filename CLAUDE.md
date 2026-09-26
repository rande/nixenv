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

The BASE flake is a shell/editor/CLI toolbox and ships **no language runtimes**
— no Node, PHP, Python, Go, Rust or Ruby, no package managers (composer, uv), no
sqlite, and no language servers that would need one (pyright, intelephense,
gopls, …). Only `lua-language-server` (for the nvim config) and
`bash-language-server` remain, since they need nothing on PATH. Languages belong
in a **per-project flake** (`build <project>`), runtime + its LSP together; the
nvim packs in the home skeleton mirror this (bash/lua only). Unit test
`02-materialize-context.sh` enforces both lists, so don't reintroduce runtimes
into the embedded flake. Note `claude-code` and the two language servers are
node applications, but nixpkgs wraps them with their own interpreter — they work
without Node on PATH.

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
  directly avoids it. Project services: the entrypoint refreshes repo-declared
  `$APP_MOUNT/.nixenv/sv/*` into `$HOME/.nixenv-sv` (persistent, in the home
  volume), then starts a background `runsv` for EVERY service dir present in the
  tree (not just repo-discovered ones — a dir installed there directly, e.g. by a
  project setup script, is supervised too). Remove a service by deleting its
  `$HOME/.nixenv-sv/<name>` dir. Declared services are refreshed from TWO
  sources each boot, repo LAST so it can override: the project flake's
  `$NIXENV_EXTRA_PROFILE/sv/<name>/run` (templates use
  `writeTextDir "sv/<name>/run"`) and `$APP_MOUNT/.nixenv/sv/<name>/run`.
  Declaring services as profile FILES is deliberate — writing them from the hook
  means nesting shell heredocs inside a Nix `''` string, where indentation
  stripping can break the terminator and silently produce an unparseable hook. **Startup hooks**: before the supervise scan (so
  hooks can add services for the same boot), the entrypoint sources every hook
  file that exists — `$NIXENV_EXTRA_PROFILE/etc/nixenv-hooks.sh` (flake-declared),
  `$APP_MOUNT/.nixenv/hooks.sh` (repo), `$HOME/.nixenv-hooks.sh` (local) — then
  calls `nixenv_pre_ssh_start` if defined. Failures warn, never block startup.
  This is the ONLY way to run project code at container start: a flake build is
  sandboxed to its `$out`, so it can't write `$HOME`/`$SVROOT` — declare the hook
  at build time (`writeTextDir "etc/nixenv-hooks.sh"`), execute at runtime. `run` maps the project's random host port → 2222.
- Arbitrary extra engine flags for a project's container come from
  `<project>/extra-parameters` — a FILE, not a CLI flag, matching
  `unrestricted`/`ports`/`hosts.extra`. `project_extra_args` strips `#` comments,
  collapses whitespace and echoes the tokens; `cmd_run` splits them into the
  `extra_args` ARRAY and expands it guarded
  (`${extra_args[@]+"${extra_args[@]}"}`) so each flag is its own argv entry.
  Contents are passed VERBATIM — there are no presets or magic tokens, so what's
  in the file is exactly what the engine receives. `write_extra_parameters`
  scaffolds a comments-only (hence no-op) file from `init` and `run`, so it's
  discoverable rather than folklore, and never clobbers an existing one. Flags
  are fixed at container creation, so edits need a `run <project>`. The commented
  example is the podman/docker-in-container set (`--security-opt
  seccomp=unconfined|apparmor=unconfined|label=disable`, `--device /dev/fuse`,
  `--device /dev/net/tun`); two caveats there — a device that doesn't exist on
  the engine host makes `run` fail outright, and the container still runs as your
  uid with no added capabilities and no `/etc/subuid`/`/etc/subgid`, so rootless
  podman inside is limited to a single UID unless the project supplies those
  mappings itself.
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
  the versioned/team-shared path. `$hostsmount` is an array of `-v` args.
- Reaching PUBLIC URLs from inside a container (`https://<p>-<port>.<domain>/`)
  needs three things, all implemented: (1) **loopback relay** — curl/libcurl (so
  also PHP ext-curl, Guzzle, Symfony HttpClient) implement RFC 6761 internally and
  force `localhost` + ANY `*.localhost` name to 127.0.0.1, IGNORING `/etc/hosts`
  and DNS. So the entrypoint installs runit services `proxy-relay-443`/`-80`
  running `socat TCP4-LISTEN:<p>,bind=127.0.0.1,fork TCP:$NIXENV_PROXY_NAME:<p>`,
  making loopback genuinely correct; it's a raw TCP relay so TLS stays end-to-end
  with caddy (SNI + Host intact). The run script `getent`s the proxy and
  `sleep 5; exit 0`s if absent — `run` starts the proxy AFTER the container, so
  runsv retries until it appears. Project containers therefore also get
  `--sysctl net.ipv4.ip_unprivileged_port_start=0`. glibc clients (PHP streams,
  Python, Go) don't share curl's rule, so they need a plain `127.0.0.1 <name>`
  entry in `hosts.extra` — loopback, NOT the proxy's IP, so everything converges
  on the relay. (An earlier `@proxy` token that resolved to the proxy container's
  IP was removed as redundant: the relay is hostname-agnostic, so loopback covers
  every client, and caddy only serves `*.PROXY_DOMAIN` anyway.)
  (2) **Port** — caddy binds **80/443 in-container** (proxy gets
  `--sysctl net.ipv4.ip_unprivileged_port_start=0`; host publish maps
  `PROXY_HTTP_PORT`/`PROXY_HTTPS_PORT` onto them), so no `:8443` suffix.
  (3) **TLS trust** — the proxy's root CA (mkcert's, or Caddy's internal via
  `export_caddy_ca` after start) is published to `~/.nixenv/proxy/certs/rootCA.pem`,
  mounted at `/etc/nixenv-proxy-ca.crt`, and merged by the entrypoint into
  `$HOME/.nixenv-ca-bundle.crt`, exported as `SSL_CERT_FILE`/`NIX_SSL_CERT_FILE`/
  `CURL_CA_BUNDLE`/`REQUESTS_CA_BUNDLE`/`GIT_SSL_CAINFO` (+ `NODE_EXTRA_CA_CERTS`,
  which Node requires instead of `SSL_CERT_FILE`). Plain service-to-service calls
  need none of this — `http://<prefix>-<project>:<port>/` already resolves.
- Per-project tooling: `build <project> [--dir=<path>]` (`cmd_build_project`)
  copies the project flake into `<project>/flake/` and
  `nix profile install path:/flake#$PROJECT_ATTR` into `/nix/var/nix/profiles/proj-<name>`
  (`project_profile`) in the same store. Default copies just `flake.nix`/`.lock`
  from `repo/`; `--dir=<path>` (relative to repo, or absolute) copies a WHOLE
  folder so a flake with local file references resolves. `run` passes the profile
  path as `NIXENV_EXTRA_PROFILE`; `.zshenv` prepends its `bin` to `PATH` (ahead of
  base) when present.
- **PATH order is `$HOME/.local/bin` → project profile → base profile**, and it
  is set in FOUR places that must agree, or a tool resolves differently depending
  on how you got a shell: the entrypoint's `.zshenv` (ssh/zmx logins), the
  entrypoint's own `export PATH` (hooks + every runit service), the ephemeral
  `run <project> cmd` branch, and `home-skel/.zshrc` (which re-asserts it because
  oh-my-zsh reorders PATH). `~/.local/bin` leads so user-installed binaries
  (`pip install --user`, pipx, hand-dropped files) win; it lives in the home
  volume so it persists, and the entrypoint `mkdir -p`s it so it exists before
  anything installs there. `10-entrypoint-content.sh` parses every
  `export PATH=` line and fails if any mentions a profile without listing
  `.local/bin` first. `delete` removes the profile; `init --build` runs the
  default mode after scaffolding.
- The Claude CLI (`claude-code` from `nixpkgs-unstable`) is on the shared
  profile. Two shared paths are bind-mounted **rw** into every container so one
  login + config is shared: `$HOME/.nixenv/claude` → `/home/app/.claude`
  (`CLAUDE_DIR`) and `$HOME/.nixenv/claude.json` → `/home/app/.claude.json`
  (`CLAUDE_JSON`). `.claude.json` lives in the home root (not inside `.claude`),
  so it's shared as its own file; `prepare_claude_share` seeds it (restoring the
  newest `.claude/backups/` if present) before each `run`.
  `CLAUDE_CODE_PROJECT_DIR_NAME=nixenv-<project>` is set in **two** places, and
  both are required: `cmd_run` passes it with `-e` (covers runit services and
  `shell`'s `docker exec`) and the entrypoint writes it into `.zshenv` (covers
  ssh/zmx logins — sshd builds a FRESH environment, so the container's `-e`
  never reaches a login shell). It must stay equal to the
  `$CLAUDE_DIR/projects/nixenv-<name>` mount or transcripts land outside the
  per-project dir; `10-entrypoint-content.sh` asserts all three agree.
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
  `stop <project>` removes that container; **`stop` with no argument** removes
  every container matching `^<prefix>(-|__)` — all projects, the shared proxy and
  any stray helper — leaving volumes/projects intact. `logs` follows a container.
- Egress restriction (ON BY DEFAULT; opt-out per project): restriction applies
  unless the `<project>/unrestricted` marker exists (`restrict <p> off` or
  `init --unrestricted` create it; `restrict <p> on` removes it; `is_restricted`
  = marker absent). `<project>/allowed_hosts` holds the validated hosts
  (domains/IPs, one per line; `allow <p> <host>…` appends; `cmd_init` auto-seeds
  the forge domain via `forge_host_from_url`, so git-to-forge works by default,
  and `init --allow=a.com,b.com` (repeatable) pre-seeds more). Entries go through
  `normalize_allowed_host` (shared by `init`/`allow`): `*.foo` → `.foo`
  (subdomains), a bare name stays EXACT, schemes/ports/paths rejected. A restricted project runs on its
  own `--internal` network `nixenv_<p>_egress` (`internal_net`/`ensure_internal_net`)
  — kernel-enforced no-route-out — with NO published ports (`-p` doesn't work on
  internal networks); its ssh/extra ports are published by the PROXY container and
  socat-relayed over the internal net. The only way out is a single shared
  **squid** (in the base flake, running inside the proxy container on
  `EGRESS_PORT` 3128, not published) with per-project ACLs keyed by the internal
  net's subnet (`net_subnet` — docker `.IPAM.Config` / podman `.Subnets`),
  default-deny, CONNECT limited to 443/22/80/9418, and denies to
  loopback/RFC1918 so projects can't reach other containers through the proxy.
  `write_egress_configs` generates `~/.nixenv/proxy/egress/{squid.conf,start.sh}`
  (start.sh = squid + socat relays + exec caddy — the proxy container's cmd) and
  fills `EGRESS_PUB`/`EGRESS_PROJECTS`; `cmd_proxy up` mounts it at `/etc/egress`,
  publishes the relay ports, and `network connect`s the proxy to every restricted
  project's internal net (so caddy ingress keeps working too). `cmd_run` passes
  `-e NIXENV_EGRESS_PROXY=http://<proxy>:3128`; the **entrypoint** then exports
  HTTP(S)_PROXY into `.zshenv` and appends a marker-guarded `ProxyCommand socat -
  PROXY:…` block to `~/.ssh/config` (ssh/git-ssh tunnel via CONNECT to validated
  hosts). **Ordering matters**: `cmd_run` starts the proxy BEFORE the container
  for a restricted project — on an internal network it's the only route out and
  the first-run hook (template setup: composer/npm/wp-cli) needs egress
  immediately; starting it afterwards made setup die with "could not resolve
  proxy". The entrypoint also waits (≤20s) for the proxy name to resolve before
  running hooks, and `cmd_run` refreshes the proxy again once the container
  exists so the ssh/port relays can target it. Starting a restricted
  project recreates the proxy (new relays/ports need a new container), but
  `allow` HOT-reloads ACLs via `squid -k reconfigure` (no proxy recreate — which
  is also why `write_egress_configs` must never `rm -rf` the bind-mounted egress
  dir: replacing the dir inode would detach the mount and reloads would read
  stale config). Squid's access log is host-visible at
  `~/.nixenv/proxy/data/egress.log`; `egress <p> [-f]` summarises allowed vs
  `TCP_DENIED` domains (filtered by the project's subnet). `delete` also removes
  the internal network (disconnecting the proxy first). Known limits: squid's ACLs filter
  traffic, not name lookups, so a reachable resolver would still answer for a
  denied host; UDP/QUIC isn't proxied; and the one-time `clone_repo` runs
  unrestricted (default bridge). Note what this looks like from INSIDE a
  restricted container: the internal network has no route out, so EXTERNAL name
  resolution fails outright — `ping google.com` → "Temporary failure in name
  resolution", and `ping`/`dig`/`nc`/QUIC can never work, since only
  proxy-aware TCP clients have an exit. That is the design, not a fault.
  Container-name DNS still resolves (it's how `nixenv-proxy` is found) and squid
  resolves the target host on the project's behalf, so
  `curl https://<allowed-host>/` succeeds while `ping` does not. `getent hosts
  nixenv-proxy` (works) vs `getent hosts google.com` (fails) is the quickest way
  to tell this apart from a real DNS problem.
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

**When working IN this repo, always invoke the tool as `./nixenv.sh <command>` —
not the installed `nixenv`.** The installed `/usr/local/bin/nixenv` (or the
Homebrew one) is a snapshot from the last `install`; while iterating on
`nixenv.sh` it will be stale, so anything you run, and every example in CLAUDE.md
or a commit message, uses `./nixenv.sh`.

**`README.md` is the exception, and deliberately so: it uses bare `nixenv`.** It
addresses users who installed via Homebrew or `install`, for whom `./nixenv.sh`
would simply not exist. The only places it keeps `./nixenv.sh` are the "Single
file" and "From a clone" install subsections (where the script genuinely is a
local file), plus a note telling clone users to substitute it. Don't "fix" the
README back to `./nixenv.sh`.

- Templates (`init --template=<name|url|path>`): a template is ONE file that
  becomes the project's `flake.nix`. `resolve_template` handles local paths,
  full URLs, and short names against `TEMPLATE_BASE` (cached in
  `~/.nixenv/templates/`); `template_meta <file> <key>` reads leading
  `# nixenv:<key> <value>` comments (`description`, `port`, `allow`, `app-path`)
  BEFORE the build, so declared egress hosts/app-path feed the normal init flow.
  `install_template` substitutes `@@PROJECT@@`/`@@APP_MOUNT@@`/`@@DOMAIN@@`/
  `@@PORT@@` and writes `flake.nix` into the app volume (never clobbers an
  existing one), then `init` forces a project build. Mutually exclusive with a
  git URL; confirms first unless `--yes`. The app itself is installed at first
  `run` by the template's **startup hook** (marker-guarded), NOT vendored in the
  flake — a build can't write the app volume. Shipped: `templates/wordpress.nix`
  (wp-cli downloads core + plugins), `templates/cloudflare.nix` (scaffolds a
  Worker, runs `wrangler dev --ip 0.0.0.0`), `templates/symfony.nix`,
  `templates/headlesscms-directus-astro.nix`, `templates/windmill.nix`
  (self-hosted Windmill: replaces upstream's docker-compose with runit services —
  `windmill-server` + two worker groups + postgres, one binary that embeds the
  frontend). Windmill is the exception to "the app lives in the app volume":
  scripts/flows live in PostgreSQL, so its hook only seeds a README, a
  `.gitignore`, an empty `workspaces/` dir, and the
  `windmill_user`/`windmill_admin` roles the migrations require. Files reach the
  app volume ONLY via `wmill sync pull`, run by hand — the CLI isn't in nixpkgs
  so the flake wraps it from JSR through the deno already in windmill's closure,
  and since sync is stateless and destructive in both directions the hook must
  never invoke it (the unit test enforces that). `wmill sync` is scoped to the
  cwd + selected workspace, hence one directory per workspace under
  `workspaces/`. It also carries
  an opt-in `useUpstreamBinary` (fetchurl + `autoPatchelfHook` on the release
  asset, x86_64 only) because nixpkgs lags upstream by ~200 releases — the same
  prebuilt-binary escape hatch the base flake uses for zmx.

`build [project]`, `init <project> [git-url] [--build]`, `run <project>`,
`ssh <project>`, `ssh-config [--install]`, `shell <project>`,
`expose <project> <port>…`, `host <project> <name:ip>…`,
`proxy [up|stop|status|logs|renew|remove-cert]`, `restrict <project> [on|off]`,
`allow <project> <host>…`, `egress <project> [-f]`, `up`, `stop`, `logs`,
`delete`/`rm`, `sync-home <project>`, `projects`, `update`, `status`,
`gc [--dry-run]` (nix-collect-garbage -d + store optimise in the builder
container; warns about running containers, which may still reference paths a
rebuild made unreachable), `clean`,
`install`, `uninstall`. See `./nixenv.sh --help` and `README.md`. `delete` prints the
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
`materialize_context` and need neither Docker nor the context. `cmd_install`
refuses when `$SCRIPT_DIR` is inside a Homebrew prefix
(`/opt/homebrew/*`, `*/Cellar/*`, `/home/linuxbrew/*`) — brew already put us on
PATH, and a second copy would never be upgraded. Intel's `/usr/local/bin`
symlink dir isn't (and can't be) matched, but it is also the default
`INSTALL_DIR`, so `src -ef dest` catches it as "already installed".

`NIXENV_VERSION` (top of the script) is printed by `-v|--version|version` and in
the `usage` header. Like `--help`/`install`, it is dispatched BEFORE
`materialize_context`, so it needs no engine, no network, and writes nothing —
`20-version-and-license.sh` asserts that ordering and that no `$CONTEXT_DIR`
appears. Bump it in the same commit as a release tag so the Homebrew formula's
`test` block can assert the two agree. Licence is **GPL-3.0-or-later**: the
verbatim FSF text is in `LICENSE` (~35 kB; the test rejects a truncated one) and
the script header carries the copyright + no-warranty notice.

**`RELEASING.md` (repo root) is the canonical release runbook** — one-time setup,
the tag-push flow, recovery from a bad tag, the manual fallback, and version
numbering. `packaging/homebrew/README.md` points at it and keeps only
formula-specific detail, so the process is described once. `22-workflows.sh`
guards against drift: it asserts the runbook names all three jobs, `NIXENV_VERSION`
and `TAP_TOKEN`, and that the tag pattern it tells people to use is byte-identical
to `release.yml`'s trigger. A stale release runbook is worse than none, because it
gets followed.

Homebrew packaging lives in `packaging/homebrew/` (formula, release helper,
publishing notes) and ships via a personal tap
(`rande/homebrew-nixenv` → `brew install rande/nixenv/nixenv`), not homebrew-core.
The formula has NO dependencies — that is load-bearing on the Bash 3.2 rule, so
`21-homebrew-formula.sh` fails if anyone adds `depends_on "bash"` without also
changing the shebang. It also asserts the formula's `url` tag equals
`NIXENV_VERSION`, since a drifted formula only breaks on users' machines.
`update-formula.sh <version>` rewrites `url`+`sha256` together from the real
GitHub tarball and refuses when the script's version, the requested version, or
the version *inside* the downloaded tarball disagree. Release order is fixed:
bump `NIXENV_VERSION` → commit → tag → `update-formula.sh` (the sha256 cannot
exist before the tag) → copy into the tap. The formula also installs
`templates/` into `pkgshare`; `TEMPLATE_BASE="file://$(brew --prefix)/share/nixenv/templates"`
pins templates to the installed release, because `resolve_template` otherwise
curls them from `main` and a tagged nixenv can pull templates that moved on
(curl handles `file://`, so short names keep working).

CI/release live in `.github/workflows/` and are covered by `22-workflows.sh`
(trigger shape, job dependency chain, and that the guards exist). That test must
NOT depend on PyYAML: GitHub's **macOS** runner ships a `python3` with no `yaml`
module, which failed the whole file. The structural checks are therefore textual
(an `awk` `job_needs` helper asserts the scalar `needs: <job>` form, so a list
form is deliberately unsupported), with a real `yaml.safe_load` only as a bonus
when the module happens to exist — GitHub rejects malformed workflow YAML on push
anyway. `actions/checkout` must be **v5+**; v4 declares `using: node20`, which
runners force onto node24 with a deprecation warning on every run, and the test
rejects `@v1`–`@v4`.
`ci.yml` runs the unit suite on push/PR across ubuntu **and macos** — macOS is
the one that actually exercises the Bash 3.2 rule. `release.yml` fires only on
`v[0-9]+.[0-9]+.[0-9]+` tags, in three dependent jobs: `verify` (tag must equal
`NIXENV_VERSION`, `bash -n`, unit suite, `--version` smoke test) → `release` (`gh
release create --generate-notes`, attaching `nixenv.sh` + `LICENSE` so people can
install the single file without brew or git) → `formula` (runs
`update-formula.sh`, commits the formula to the default branch, pushes it to the
tap). The formula job calls the SAME script you'd run locally rather than
recomputing the sha inline — `22-workflows.sh` fails if a `sha256sum`/`shasum`
appears in the workflow. It needs a `TAP_TOKEN` secret (fine-grained PAT with
Contents: write on the tap; `GITHUB_TOKEN` cannot push to another repo) and, when
that is unset, skips with a `::notice::` instead of failing the release — secrets
aren't available in a job-level `if`, so the gate is a step that sets an output.

## Writing templates — hard-won rules

Each template in `templates/` is ONE file that becomes a project's `flake.nix`.
These rules come from bugs that actually shipped; violating them fails silently,
which is why the shared test contract in `tests/lib-template.sh` enforces most
of them. Add a `tests/unit/1N-template-<name>.sh` for every new template.

- **Declare services as FILES, never write them from the hook.** Use
  `pkgs.writeTextDir "sv/<name>/run"`; the entrypoint copies `sv/*` from the
  profile into `$SVROOT` each boot. Writing run scripts with `cat > … <<'SV'`
  *inside* a Nix `''` string is the trap: Nix strips the minimum common
  indentation, so one stray line changes the strip amount, the heredoc
  terminator ends up indented, the heredoc never closes, the hook file becomes
  invalid shell — and the entrypoint (which tolerates hook failures by design)
  just warns and continues with NO services registered.
- **A Nix build cannot write the app volume** (sandboxed to `$out`). Anything
  that creates project files — `wp core download`, `composer create-project`,
  `npm install`, scaffolding — belongs in the startup hook, guarded by a marker
  file under `$APP_MOUNT/.nixenv/.<template>-installed` so restarts stay instant.
- **Scratch dirs must be writable by the non-root `app` user.** `"$APP.tmp"` is
  the trap: with `APP=/app` that's `/app.tmp` at the filesystem ROOT, which
  `app` cannot create — the setup dies with permission denied and (because the
  marker is only written on success) leaves an app volume holding just
  `flake.nix`. Use `$HOME/.nixenv-run/<scratch>` or a dir inside the app volume.
  Generators that need an EMPTY target (`composer create-project`) must build in
  scratch and copy in, then **assert the expected file exists** and fail loudly
  rather than leaving a half-made project.
- **nginx and php-fpm do NOT expand env vars in their configs.** `${HOME}` there
  is a literal broken path; use `/home/app/...` (the runtime user is always
  `app`). Only the `sv/*/run` scripts, being shell, can use `$HOME`.
- **Never write a bare `''` in a comment that sits INSIDE an indented string.**
  `''` both opens and closes such a string, so a comment like `# … a Nix ''
  string …` terminates it right there; Nix then reports a syntax error pointing
  at the *comment*, several lines away from anything that looks wrong. Two of
  them cancel out, so a parity check won't save you — say "indented string" in
  prose, or escape it as `'''`. `assert_template` rejects any indented comment
  containing a bare `''` (top-level comments, at column 0, are fine).
- **In Nix `''` strings, escape shell `${…}` as `''${…}`** (e.g.
  `''${NIXENV_APP_MOUNT:-/app}`), otherwise Nix tries to interpolate it. A bare
  `$VAR` is already literal.
- **Dev servers must bind `0.0.0.0`** (`--host`, `--ip`, `HOST=`), never
  localhost: the reverse proxy is a different container. The declared
  `# nixenv:port` must match the port the stack actually serves.
- **Watch for `buildEnv` path collisions.** Two packages shipping the same file
  fail the build with "two given paths contain a conflicting subpath" —
  node tools that vendor their deps are the usual culprits (`wrangler` bundles
  `typescript`; `mysql-client` overlaps `mariadb`). Fix with
  `(pkgs.lib.hiPrio pkgs.<winner>)` — the base flake uses the same trick for
  `git`, and `templates/cloudflare.nix` for `typescript` — or drop the
  redundant package.
- **Services need their dependencies to exist.** Each `run` script must `exec` a
  FOREGROUND process, and should wait for what it needs (php-fpm socket, DB
  ready) with a short `sleep; exit 0` — runsv retries, so exiting is the
  throttle. First-run setup happens BEFORE services start, so if the hook needs
  a database it must start a temporary one itself and shut it down afterwards.
- **Templates are egress-restricted by default**, so declare every host the
  setup needs in `# nixenv:allow` — the metadata is read before the build and
  seeded into `allowed_hosts`. Missing entries surface as `TCP_DENIED` in
  `nixenv egress <project>`.
- Metadata (`description`, `port`, `allow`, `app-path`) is parsed from leading
  `# nixenv:<key>` comments; the header should also show the `init` command.
  Only `@@PROJECT@@`, `@@APP_MOUNT@@`, `@@DOMAIN@@`, `@@PORT@@` are substituted.

## Conventions

- Keep the script POSIX-friendly where it runs as `/bin/sh` (the entrypoint) and
  Bash for `nixenv.sh` itself (`#!/usr/bin/env bash`, `set -euo pipefail`).
- Support macOS Bash 3.2: guard empty-array expansions and avoid Bash-4-only
  features.
- `$HOME/.nixenv/projects/` holds user data (SSH keys, per-project home) — it
  lives outside the repo; never commit it and avoid destructive operations on it.

## Verifying changes

After editing `nixenv.sh`, ALWAYS run the unit suite (fast, no docker):

```sh
./tests/run.sh                    # unit tests — must stay green
```

Test layout: one bash file per test in `tests/unit/` and `tests/integration/`,
shared harness `tests/lib.sh` (exit 0 pass / 77 skip / else fail), plus
`tests/lib-template.sh` whose `assert_template <name>` encodes the template
rules above (metadata valid, hook present, services declared as files, markers,
placeholders, 0.0.0.0 binding),
`tests/run.sh [unit|integration|all|<files>]` runner. Integration needs a real
engine and a DEDICATED environment (isolated `nxt-*` prefix + state dirs; sweeps
by prefix; reuses the shared store volume). `tests/run-in-docker.sh` runs
everything inside disposable docker-in-docker (cache volume
`nixenv-dind-cache`). Unit tests SOURCE `nixenv.sh` — the script only executes
`main` when run directly (`BASH_SOURCE` guard at the bottom); test-isolation env
hooks: `NIXENV_PROJECTS_DIR`, `PROXY_DIR`, `CLAUDE_DIR`, `CLAUDE_JSON`,
`CONTEXT_DIR`, `CONTAINER_PREFIX`. When adding a feature, add a unit test for
its pure logic and (if it touches containers) an integration test file.

Quick manual check without the suite:

```sh
bash -n nixenv.sh                 # syntax check the script
CONTEXT_DIR=/tmp/ctx ./nixenv.sh status   # materialise embedded files
sh -n /tmp/ctx/entrypoint.sh      # syntax check the generated entrypoint
```

A full `build` + `run` requires a working Docker daemon.
