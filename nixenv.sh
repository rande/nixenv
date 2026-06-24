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
# Per-project layout:
#   <project>/home        → copied into /home/app (.ssh, .zshrc, configs)
#   docker volume <name>_app → mounted at /app (your code; WORKDIR)
# =============================================================================

set -euo pipefail

# ── Configuration (override via env) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_DIR="${CONTEXT_DIR:-$HOME/.nixenv/context}"  # embedded files written here
FLAKE_DIR="${FLAKE_DIR:-$CONTEXT_DIR}"               # dir containing flake.nix
HOME_SKEL="${HOME_SKEL:-$CONTEXT_DIR/home-skel}"     # project home template
ENTRYPOINT_FILE="${ENTRYPOINT_FILE:-$CONTEXT_DIR/entrypoint.sh}"
NIX_VOLUME="${NIX_VOLUME:-nixos-store}"              # standalone Docker volume for /nix
BUILDER_IMAGE="${BUILDER_IMAGE:-nixos/nix:2.32.8}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-debian:stable-slim}"
FLAKE_REF="${FLAKE_REF:-.#default}"                  # what to build/install from the flake
PROFILE="${PROFILE:-/nix/var/nix/profiles/shared}"  # profile path INSIDE /nix
CONTAINER_PREFIX="${CONTAINER_PREFIX:-nixenv}"       # container name = <prefix>-<project>
APP_USER="${APP_USER:-app}"                          # non-root user in the runtime container
PROJECTS_DIR="$HOME/.nixenv/projects"                # all projects live here
CLAUDE_DIR="$HOME/.nixenv/claude"                    # shared Claude CLI creds/config dir (~/.claude)
CLAUDE_JSON="$HOME/.nixenv/claude.json"              # shared Claude global config file (~/.claude.json)
CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"             # docker|podman; empty = auto-detect
ENGINE_FILE="$HOME/.nixenv/engine"                   # remembered engine choice
ENGINE=""                                            # resolved at runtime

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
  mkdir -p "$c/home-skel/.config/zellij" "$c/home-skel/.ssh"

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
              rsync
              jq
              yq-go
              ripgrep
              fd
              fzf
              bat
              zoxide
              tree
              tmux
              zellij
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

              # ── Languages & runtimes ───────────────────────────────────────
              nodejs_22
              go
              rustup
              php85
              php85Packages.composer
              python312
              uv
              sqlite

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
        nixpkgs.fzf nixpkgs.bat nixpkgs.zoxide nixpkgs.tree nixpkgs.tmux \
        nixpkgs.zellij nixpkgs.direnv nixpkgs.starship nixpkgs.tldr nixpkgs.ncdu \
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
# Runtime container entrypoint (runs as root, then drops to the app user)
# =============================================================================
# - Creates a non-root `app` user whose login shell is the shared-store zsh.
# - Seeds /home/app from the project home mounted read-only at /seed, so .ssh
#   and config files are *copied* into the container fs — letting us enforce
#   strict perms regardless of how the host bind-mount exposes ownership.
# - Hands off to zsh (with starship/oh-my-zsh) as the app user.
# =============================================================================
set -eu

APP_USER="${APP_USER:-app}"
APP_UID="${APP_UID:-1000}"
APP_GID="${APP_GID:-1000}"
PROFILE="${PROFILE:-/nix/var/nix/profiles/shared}"
ZSH_BIN="$PROFILE/bin/zsh"
HOME_DIR="/home/$APP_USER"

# Never collide with root.
[ "$APP_UID" = "0" ] && APP_UID=1000
[ "$APP_GID" = "0" ] && APP_GID=1000

# --- Create group + user (idempotent; works with passwd or adduser tools) ----
if ! getent group "$APP_GID" >/dev/null 2>&1; then
  groupadd -g "$APP_GID" "$APP_USER" 2>/dev/null \
    || addgroup --gid "$APP_GID" "$APP_USER" 2>/dev/null || true
fi
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd -u "$APP_UID" -g "$APP_GID" -d "$HOME_DIR" -s "$ZSH_BIN" -M "$APP_USER" 2>/dev/null \
    || adduser --disabled-password --gecos "" --uid "$APP_UID" --gid "$APP_GID" \
               --home "$HOME_DIR" --shell "$ZSH_BIN" "$APP_USER" 2>/dev/null || true
fi
# Blank the app account password so SSH can log in with no key and no password
# (local-dev convenience; the port is published on 127.0.0.1 only).
passwd -d "$APP_USER" 2>/dev/null || usermod -p '' "$APP_USER" 2>/dev/null || true
mkdir -p "$HOME_DIR"

# --- Seed home from the mounted project home (copy, not bind) ----------------
if [ -d /seed ]; then
  cp -a /seed/. "$HOME_DIR"/ 2>/dev/null || cp -R /seed/. "$HOME_DIR"/ 2>/dev/null || true
fi

# --- Make the shared profile + shell config available to every zsh -----------
# .zshenv is sourced for login and non-login shells alike.
cat > "$HOME_DIR/.zshenv" <<EOF
export PROFILE="$PROFILE"
export PATH="$PROFILE/bin:\$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export ZSH="$PROFILE/share/oh-my-zsh"
export ZSH_CACHE_DIR="\$HOME/.cache/omz"
export SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt"
export NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt"
export NIXENV_PROJECT="${NIXENV_PROJECT:-}"
export EDITOR=vim
export LANG=C.UTF-8
EOF
mkdir -p "$HOME_DIR/.cache/omz"

# --- Build authorized_keys from any *.pub if absent (for inbound SSH) --------
if [ -d "$HOME_DIR/.ssh" ] && [ ! -f "$HOME_DIR/.ssh/authorized_keys" ]; then
  for pub in "$HOME_DIR"/.ssh/*.pub; do
    [ -f "$pub" ] || continue
    cat "$pub" >> "$HOME_DIR/.ssh/authorized_keys"
  done
fi

# --- Ownership + strict SSH perms --------------------------------------------
chown -R "$APP_UID:$APP_GID" "$HOME_DIR"
if [ -d "$HOME_DIR/.ssh" ]; then
  chmod 700 "$HOME_DIR/.ssh"
  find "$HOME_DIR/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true
fi

# Give the app user ownership of its working copy (the project's app volume).
# Disable with APP_CHOWN_REPO=0 if you don't want ownership changed.
if [ "${APP_CHOWN_REPO:-1}" = "1" ] && [ -d /app ]; then
  chown -R "$APP_UID:$APP_GID" /app 2>/dev/null || true
fi

# =============================================================================
# Command mode: run the given command as the app user, then exit.
# =============================================================================
if [ "$#" -gt 0 ]; then
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$APP_USER" -- "$ZSH_BIN" -lc 'exec "$@"' zsh "$@"
  else
    exec su "$APP_USER" -s "$ZSH_BIN" -c "exec $*"
  fi
fi

# =============================================================================
# Service mode: configure sshd + runit, then hand PID 1 to runsvdir so the
# container stays up and you can SSH into it. sshd listens on 22 inside the
# container; the host-side port mapping is done by `docker run -p`.
# =============================================================================
SSHD="$PROFILE/bin/sshd";             [ -x "$SSHD" ]      || SSHD="$(command -v sshd || true)"
SSHKEYGEN="$PROFILE/bin/ssh-keygen";  [ -x "$SSHKEYGEN" ] || SSHKEYGEN="$(command -v ssh-keygen || true)"
RUNSVDIR="$PROFILE/bin/runsvdir";     [ -x "$RUNSVDIR" ]  || RUNSVDIR="$(command -v runsvdir || true)"
[ -n "$SSHD" ]     || { echo "nixenv: sshd not found in profile"; exit 1; }
[ -n "$RUNSVDIR" ] || { echo "nixenv: runsvdir (runit) not found in profile"; exit 1; }

# sshd needs a privilege-separation user and an empty, root-owned 0711 dir.
id sshd >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin sshd 2>/dev/null \
  || adduser --system --no-create-home --shell /usr/sbin/nologin sshd 2>/dev/null || true
mkdir -p /var/empty /run/sshd && chmod 711 /var/empty
mkdir -p /etc/ssh

# Host keys (into a writable dir; the Nix sysconfdir is read-only).
for t in ed25519 rsa; do
  f="/etc/ssh/ssh_host_${t}_key"
  [ -f "$f" ] || "$SSHKEYGEN" -t "$t" -f "$f" -N "" -q
done

# Optional sftp subsystem.
SFTP="$(ls "$PROFILE"/libexec/sftp-server 2>/dev/null || ls "$PROFILE"/libexec/openssh/sftp-server 2>/dev/null || true)"

{
  echo "Port 22"
  echo "HostKey /etc/ssh/ssh_host_ed25519_key"
  echo "HostKey /etc/ssh/ssh_host_rsa_key"
  echo "PidFile /run/sshd.pid"
  echo "PermitRootLogin no"
  # Open local-dev login: no key and no password required. The app account has a
  # blank password and sshd permits empty passwords, so the SSH 'none' method
  # succeeds and you connect with no prompt. Pubkey still works if keys present.
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication yes"
  echo "PermitEmptyPasswords yes"
  echo "KbdInteractiveAuthentication no"
  echo "AuthorizedKeysFile .ssh/authorized_keys"
  echo "AllowUsers $APP_USER"
  echo "UsePAM no"
  echo "PrintMotd no"
  echo "AcceptEnv LANG LC_*"
  [ -n "$SFTP" ] && echo "Subsystem sftp $SFTP"
} > /etc/ssh/sshd_config

# runit service tree: one supervised sshd.
SVDIR=/etc/service
mkdir -p "$SVDIR/sshd"
cat > "$SVDIR/sshd/run" <<RUN
#!/bin/sh
exec "$SSHD" -D -e -f /etc/ssh/sshd_config
RUN
chmod +x "$SVDIR/sshd/run"

echo "nixenv: sshd ready — open login as '$APP_USER' (no key/password needed)"

# runsvdir spawns its `runsv` children via PATH, so the profile bin must be on
# PATH or no service starts (you'd see a defunct runsvdir child and no sshd).
export PATH="$PROFILE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
exec "$RUNSVDIR" "$SVDIR"
NIXENV_ENTRYPOINT

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

# --- Shared profile on PATH ---
export PATH="$PROFILE/bin:$HOME/.cargo/bin:$PATH"

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

# Jump into the mounted repo on login.
[ -d /app ] && cd /app 2>/dev/null || true
NIXENV_ZSHRC

  cat > "$c/home-skel/.gitconfig" <<'NIXENV_GITCONFIG'
[include]
	path = ~/.gitconfig.identity
	path = ~/.gitconfig.credentials

[init]
	defaultBranch = main
[core]
	pager = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	navigate = true
	side-by-side = true
[merge]
	conflictstyle = diff3
[diff]
	colorMoved = default
NIXENV_GITCONFIG

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

  cat > "$c/home-skel/.config/zellij/config.kdl" <<'NIXENV_ZELLIJ'
theme "default"
default_shell "zsh"
pane_frames true
default_layout "compact"
NIXENV_ZELLIJ

  cat > "$c/home-skel/.tmux.conf" <<'NIXENV_TMUX'
set -g mouse on
set -g history-limit 50000
set -g default-terminal "tmux-256color"
NIXENV_TMUX

  cat > "$c/home-skel/.vimrc" <<'NIXENV_VIMRC'
set nocompatible
syntax on
set number
set expandtab shiftwidth=2 tabstop=2
set ignorecase smartcase
NIXENV_VIMRC

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

# True once the shared profile has been populated inside the volume.
store_is_populated() {
  "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
    sh -c "[ -e '$PROFILE/bin' ]" >/dev/null 2>&1
}

# ── Project helpers ──────────────────────────────────────────────────────────
project_dir()    { printf '%s/%s' "$PROJECTS_DIR" "$1"; }
repo_volume()    { printf '%s_app' "$1"; }                 # named volume backing /app
container_name() { printf '%s-%s' "$CONTAINER_PREFIX" "$1"; }
container_exists()  { "$ENGINE" ps -a --format '{{.Names}}' | grep -qx "$1"; }
container_running() { "$ENGINE" ps    --format '{{.Names}}' | grep -qx "$1"; }

# Prepare the shared Claude state mounted into every container.
#   ~/.nixenv/claude       → /home/app/.claude       (creds, settings, backups)
#   ~/.nixenv/claude.json  → /home/app/.claude.json  (global config file)
# Claude keeps ~/.claude.json in the home root (outside the .claude dir), so we
# share it as its own file. If it's missing but Claude left a backup in the
# shared dir, restore the newest one so state carries over.
prepare_claude_share() {
  mkdir -p "$CLAUDE_DIR/backups"

  # Is the current global config effectively unconfigured? (missing, empty, {})
  local need_restore=0 content=""
  if [ ! -f "$CLAUDE_JSON" ]; then
    need_restore=1
  else
    content="$(tr -d '[:space:]' < "$CLAUDE_JSON" 2>/dev/null || true)"
    if [ -z "$content" ] || [ "$content" = "{}" ]; then need_restore=1; fi
  fi

  if [ "$need_restore" = 1 ]; then
    local latest
    latest="$(ls -1t "$CLAUDE_DIR"/backups/.claude.json.backup.* 2>/dev/null | head -1 || true)"
    if [ -n "$latest" ] && [ -f "$latest" ]; then
      cp "$latest" "$CLAUDE_JSON"
      log "restored Claude config from $(basename "$latest")"
    elif [ ! -f "$CLAUDE_JSON" ]; then
      printf '{}\n' > "$CLAUDE_JSON"
    fi
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

# Clone a git repo into the project's app volume (must be empty). Uses the
# debian runtime image with the shared Nix store mounted, so the clone runs with
# the store's git and the project's SSH keys (via the entrypoint), writing
# straight into the volume — no extra image to pull.
clone_repo() {
  local url="$1" name="$2"
  require_engine
  local pdir vol; pdir="$(project_dir "$name")"; vol="$(repo_volume "$name")"

  if ! store_is_populated; then
    warn "shared store not built yet — skipping clone"
    warn "run '$0 build', then '$0 init $name $url' to clone into the volume"
    return 0
  fi
  if [ -n "$("$ENGINE" run --rm -v "$vol":/app "$(img "$RUNTIME_IMAGE")" sh -c 'ls -A /app' 2>/dev/null)" ]; then
    warn "volume '$vol' not empty — skipping clone"
    return 0
  fi

  log "Cloning $url → volume '$vol' (/app) via $RUNTIME_IMAGE + shared git"
  "$ENGINE" run --rm \
    -v "$NIX_VOLUME":/nix:ro \
    -v "$pdir/home":/seed:ro \
    -v "$vol":/app \
    -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
    -w /app \
    -e PROFILE="$PROFILE" \
    -e APP_USER="$APP_USER" \
    -e APP_UID="$(id -u)" \
    -e APP_GID="$(id -g)" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
    "$(img "$RUNTIME_IMAGE")" \
    sh /usr/local/bin/nixenv-entrypoint git clone "$url" /app
  ok "cloned into volume '$vol'"
}

# Scaffold <name>/home + app volume, seed home/, set git identity, optional clone.
#   usage: init <project> [git-repo-url]
cmd_init() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 init <project> [git-repo-url]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  local git_url="${2:-}"

  local pdir; pdir="$(project_dir "$name")"
  log "Initialising project '$name' at $pdir"
  mkdir -p "$pdir/home"

  # Seed home from the skeleton WITHOUT clobbering existing files.
  if [ -d "$HOME_SKEL" ]; then
    cp -Rn "$HOME_SKEL/." "$pdir/home/" 2>/dev/null || true
  fi

  # SSH needs strict perms or ssh/git refuse the keys.
  mkdir -p "$pdir/home/.ssh"
  chmod 700 "$pdir/home/.ssh"
  find "$pdir/home/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true

  # Git identity (prompted) + optional HTTPS credentials + optional clone.
  configure_git_identity "$pdir"
  if [ -n "$git_url" ]; then
    configure_git_credentials "$pdir" "$git_url"
    clone_repo "$git_url" "$name"
  fi

  # Assign a stable random SSH port for this project.
  local port; port="$(project_port "$name")"

  ok "Project '$name' ready"
  echo "   home → /home/$APP_USER  ($pdir/home — drop SSH keys in home/.ssh)"
  echo "   repo → /app             (docker volume $(repo_volume "$name"))"
  echo "   ssh  → host port $port  (add your public key to home/.ssh/authorized_keys)"
}

# Auto-scaffold a project if missing.
ensure_project() {
  local name="$1" pdir; pdir="$(project_dir "$name")"
  if [ ! -d "$pdir/home" ]; then
    warn "Project '$name' not initialised — scaffolding it now"
    cmd_init "$name"
  fi
}

# =============================================================================
# build — download all flake deps into the standalone volume
# =============================================================================
cmd_build() {
  require_engine
  [ -f "$FLAKE_DIR/flake.nix" ] || die "no flake.nix in $FLAKE_DIR"
  ensure_volume

  log "Building flake deps '$FLAKE_REF' from $FLAKE_DIR into volume '$NIX_VOLUME' (slow the first time)"

  # Mount:
  #   - the volume at /nix          → the shared store gets populated here
  #   - the flake dir at /flake (rw) → so nix can write/refresh flake.lock
  "$ENGINE" run --rm \
    -v "$NIX_VOLUME":/nix \
    -v "$FLAKE_DIR":/flake \
    -w /flake \
    -e NIX_CONFIG=$'experimental-features = nix-command flakes\nmax-jobs = auto' \
    "$(img "$BUILDER_IMAGE")" \
    sh -euc '
      echo "--- resetting shared profile (so flake changes take effect) ---"
      rm -f "'"$PROFILE"'" "'"$PROFILE"'"-*-link 2>/dev/null || true
      echo "--- nix profile install into shared profile ---"
      # --profile keeps the GC root + symlinks inside /nix (the volume),
      # so the runtime container sees them.
      nix profile install "'"$FLAKE_REF"'" \
        --profile "'"$PROFILE"'" \
        --accept-flake-config \
        --print-build-logs
      echo "--- optimising store (hardlink identical files) ---"
      nix store optimise || true
      echo "--- installed profile contents ---"
      ls -1 "'"$PROFILE"'/bin" | head -n 40
    '

  ok "Dependencies downloaded into volume '$NIX_VOLUME'"
  log "Profile available inside the store at: $PROFILE"
}

# =============================================================================
# run — start the project's background service (sshd under runit)
#   usage: run <project>
# =============================================================================
cmd_run() {
  require_engine
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 run <project> [cmd...]"
  shift
  case "$name" in */*|.|..) die "invalid project name: $name";; esac

  volume_exists || die "volume '$NIX_VOLUME' missing — run '$0 build' first"
  store_is_populated || die "shared profile not found in volume — run '$0 build' first"
  ensure_project "$name"

  local pdir; pdir="$(project_dir "$name")"
  [ -f "$ENTRYPOINT_FILE" ] || die "missing entrypoint at $ENTRYPOINT_FILE"

  # Match the in-container app user to the host uid/gid so the app volume stays
  # writable on Linux (harmless/permissive on Docker Desktop).
  local host_uid host_gid app_vol cname
  host_uid="$(id -u)"; host_gid="$(id -g)"
  app_vol="$(repo_volume "$name")"
  cname="$(container_name "$name")"
  [ "$#" -eq 0 ] || die "run takes no command — use '$0 shell $name' or '$0 ssh $name'"
  prepare_claude_share   # shared Claude creds + global config, mounted rw

  # --- Start a detached container running sshd under runit -------------------
  local port; port="$(project_port "$name")"

  # Published ports: ssh (loopback) + any specs from <project>/ports.
  # Each non-comment line: "8080" → 127.0.0.1:8080:8080, or a full docker spec
  # like "3000:3000", "0.0.0.0:8080:80", "127.0.0.1:5173:5173".
  local pub; pub=(-p "127.0.0.1:$port:22")
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

  if container_running "$cname"; then
    ok "Project '$name' already running as '$cname'"
  else
    container_exists "$cname" && "$ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
    log "Starting service '$cname' ($RUNTIME_IMAGE) — sshd on 127.0.0.1:$port, repo volume '$app_vol' → /app"
    "$ENGINE" run -d \
      --name "$cname" \
      "${pub[@]}" \
      -v "$NIX_VOLUME":/nix:ro \
      -v "$pdir/home":/seed:ro \
      -v "$app_vol":/app \
      -v "$CLAUDE_DIR":/home/"$APP_USER"/.claude \
      -v "$CLAUDE_JSON":/home/"$APP_USER"/.claude.json \
      -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
      -w /app \
      -e PROFILE="$PROFILE" \
      -e APP_USER="$APP_USER" \
      -e APP_UID="$host_uid" \
      -e APP_GID="$host_gid" \
      -e NIXENV_PROJECT="$name" \
      "$(img "$RUNTIME_IMAGE")" \
      sh /usr/local/bin/nixenv-entrypoint >/dev/null
    ok "Started '$cname'"
  fi
  echo "   ssh:    ssh -p $port $APP_USER@127.0.0.1   (or: $0 ssh $name)"
  echo "   shell:  $0 shell $name   ($ENGINE exec, no key needed)"
  if [ -f "$pdir/ports" ] && grep -q '[^[:space:]]' "$pdir/ports" 2>/dev/null; then
    echo "   ports:  $(grep -v '^[[:space:]]*#' "$pdir/ports" | tr -s '[:space:]' ' ')"
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
#   usage: up <project> [cmd...]
# =============================================================================
cmd_up() {
  require_engine
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 up <project> [cmd...]"
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
  local cname; cname="$(container_name "$name")"
  container_running "$cname" || cmd_run "$name"
  exec "$ENGINE" exec -it -u "$APP_USER" -w /app \
    -e HOME="/home/$APP_USER" \
    -e TERM="${TERM:-xterm-256color}" \
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
  exec ssh -p "$port" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    "$APP_USER@127.0.0.1"
}

# =============================================================================
# stop — stop and remove a project's service container
# =============================================================================
cmd_stop() {
  require_engine
  local name="${1:-}"; [ -n "$name" ] || die "usage: $0 stop <project>"
  local cname; cname="$(container_name "$name")"
  container_exists "$cname" || { warn "'$cname' is not running"; return 0; }
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

  local pdir vol cname
  pdir="$(project_dir "$name")"
  vol="$(repo_volume "$name")"
  cname="$(container_name "$name")"

  [ -d "$pdir" ] || warn "no project home at $pdir (will still try its container/volume)"

  log "This will PERMANENTLY delete project '$name' by running:"
  if [ -n "$ENGINE" ]; then
    echo "    $ENGINE rm -f $cname"
    echo "    $ENGINE volume rm $vol"
  else
    warn "no container engine detected — its container/volume won't be removed"
  fi
  echo "    rm -rf $pdir"
  warn "This cannot be undone (code volume, SSH keys, stored git credentials, port)."

  printf 'Proceed? [y/N] '
  local ans=""; read -r ans || true
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *) warn "Aborted — nothing deleted"; return 0 ;;
  esac

  if [ -n "$ENGINE" ]; then
    "$ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
    "$ENGINE" volume rm "$vol" >/dev/null 2>&1 || true
  fi
  rm -rf "$pdir"
  ok "Deleted project '$name'"
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
  "$ENGINE" run --rm \
    -v "$FLAKE_DIR":/flake -w /flake \
    -e NIX_CONFIG=$'experimental-features = nix-command flakes' \
    "$(img "$BUILDER_IMAGE")" nix flake update
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
    local size
    size=$("$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" du -sh /nix 2>/dev/null | cut -f1 || echo '?')
    echo "   store size: $size"
    if store_is_populated; then ok "Shared profile present at $PROFILE"; else warn "Shared profile not built yet"; fi
  else
    warn "Volume '$NIX_VOLUME' does not exist (run '$0 build')"
  fi
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
nixenv.sh — self-contained shared Nix dev environment in a Docker volume

Usage: $0 <command> [args]

On every run the embedded context (flake.nix, Dockerfile, entrypoint, home
skeleton) is written to \$CONTEXT_DIR and the build runs from there.

Commands:
  build                     (Re)write context, then download all flake deps
                            into the volume '$NIX_VOLUME'
  init <project> [git-url]  Scaffold <project>/home + the <project>_app volume;
                            prompts for git name/email; clones git-url into the
                            app volume if given
  run <project>             Start the project as a background service (sshd under
                            runit); prints the SSH port
  ssh <project>             SSH into the running service (auto-starts it)
  shell <project>           Interactive zsh via the engine's 'exec' (no SSH key)
  expose <project> <port>…  Publish extra port(s) (e.g. 8080 or 3000:3000),
                            stored in <project>/ports; restarts to apply
  up <project>              build if needed, then start the service
  stop <project>            Stop & remove the project's service container
  logs <project>            Follow the service container logs
  delete <project>          Permanently remove a project (container, code volume,
                            home dir) — prints the commands and asks to confirm
  projects                  List projects with their SSH port and state
  update                    Refresh flake.lock, then rebuild into the volume
  status                    Show context + volume + shared-profile state
  clean                     Delete the standalone volume (removes shared packages)
  install                   Copy this script onto your PATH (as '${INSTALL_NAME:-nixenv}')
  uninstall                 Remove the installed copy

Per-project (runtime runs as non-root user '$APP_USER'):
  <project>/home        → copied into /home/$APP_USER (.ssh, .zshrc, configs)
  <project>/port        → the project's stable random host SSH port
  volume <project>_app  → /app  (your code; WORKDIR)

SSH: each project gets a random host port (stored once in <project>/port). The
container runs sshd via runit; add your public key to home/.ssh/authorized_keys
(or drop an *.pub there) to log in as '$APP_USER'.

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

Projects always live in $PROJECTS_DIR.

Examples:
  $0 build                                  # populate the volume once
  $0 init myapp                             # scaffold + prompt for git identity
  $0 init myapp git@github.com:me/app.git   # also clone into the app volume
  $0 run myapp                              # start the service (prints SSH port)
  $0 ssh myapp                              # SSH in as 'app'
  $0 shell myapp                            # interactive zsh via engine exec
  $0 stop myapp                             # stop the service

Skip the git prompt by exporting GIT_USER_NAME / GIT_USER_EMAIL before init.
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    ""|-h|--help|help) usage; return 0;;
    install)   cmd_install "$@"; return $?;;
    uninstall) cmd_uninstall "$@"; return $?;;
  esac

  # Always (re)materialise the embedded context first, then run from it.
  materialize_context

  case "$cmd" in
    build)    cmd_build "$@";;
    init)     cmd_init "$@";;
    run)      cmd_run "$@";;
    up)       cmd_up "$@";;
    shell)    cmd_shell "$@";;
    ssh)      cmd_ssh "$@";;
    expose)   cmd_expose "$@";;
    stop)     cmd_stop "$@";;
    logs)     cmd_logs "$@";;
    delete|rm) cmd_delete "$@";;
    projects) cmd_projects "$@";;
    update)   cmd_update "$@";;
    status)   cmd_status "$@";;
    clean)    cmd_clean "$@";;
    *) die "unknown command: $cmd (try '$0 --help')";;
  esac
}

main "$@"
