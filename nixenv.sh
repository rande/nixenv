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
# Per-project layout (under $PROJECTS_DIR, created on demand):
#   <project>/home  → copied into /home/app (.ssh, .zshrc, configs)
#   <project>/repo  → mounted at /app (your code; WORKDIR)
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
PROJECTS_DIR="${PROJECTS_DIR:-$SCRIPT_DIR/projects}" # holds all projects
APP_USER="${APP_USER:-app}"                          # non-root user in the runtime container

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

  # Pinned to the same channel the reference Dockerfile used.
  # Bump this tag (and run `nix flake update`) to roll all tools forward.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
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
              cacert

              # ── Languages & runtimes ───────────────────────────────────────
              nodejs_22
              go
              rustup
              php83
              php83Packages.composer
              python312
              uv
              sqlite

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
ARG PHP_PKG=83
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
export EDITOR=vim
export LANG=C.UTF-8
EOF
mkdir -p "$HOME_DIR/.cache/omz"

# --- Ownership + strict SSH perms --------------------------------------------
chown -R "$APP_UID:$APP_GID" "$HOME_DIR"
if [ -d "$HOME_DIR/.ssh" ]; then
  chmod 700 "$HOME_DIR/.ssh"
  find "$HOME_DIR/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true
fi

# Give the app user ownership of its working copy (the project's repo/ folder).
# Disable with APP_CHOWN_REPO=0 if you don't want ownership changed.
if [ "${APP_CHOWN_REPO:-1}" = "1" ] && [ -d /app ]; then
  chown -R "$APP_UID:$APP_GID" /app 2>/dev/null || true
fi

# --- Drop privileges and start zsh (login → sources .zshenv + .zshrc) --------
if command -v runuser >/dev/null 2>&1; then
  if [ "$#" -eq 0 ]; then
    exec runuser -u "$APP_USER" -- "$ZSH_BIN" -l
  else
    exec runuser -u "$APP_USER" -- "$ZSH_BIN" -lc 'exec "$@"' zsh "$@"
  fi
else
  if [ "$#" -eq 0 ]; then
    exec su - "$APP_USER" -s "$ZSH_BIN"
  else
    exec su "$APP_USER" -s "$ZSH_BIN" -c "exec $*"
  fi
fi
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

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
}

# ── Volume helpers ───────────────────────────────────────────────────────────
volume_exists()  { docker volume inspect "$NIX_VOLUME" >/dev/null 2>&1; }
ensure_volume()  {
  if volume_exists; then
    ok "Volume '$NIX_VOLUME' already exists"
  else
    log "Creating standalone volume '$NIX_VOLUME'"
    docker volume create "$NIX_VOLUME" >/dev/null
    ok "Volume created"
  fi
}

# True once the shared profile has been populated inside the volume.
store_is_populated() {
  docker run --rm -v "$NIX_VOLUME":/nix "$BUILDER_IMAGE" \
    sh -c "[ -e '$PROFILE/bin' ]" >/dev/null 2>&1
}

# ── Project helpers ──────────────────────────────────────────────────────────
project_dir() { printf '%s/%s' "$PROJECTS_DIR" "$1"; }

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

# Clone a git repo into the (empty) project repo/ dir. Uses host git if present,
# otherwise an alpine/git container so no host git is required.
clone_repo() {
  local url="$1" dest="$2"
  if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    warn "repo dir not empty — skipping clone into $dest"
    return 0
  fi
  log "Cloning $url → $dest"
  if command -v git >/dev/null 2>&1; then
    git clone "$url" "$dest"
  else
    require_docker
    warn "host git not found — cloning via alpine/git container"
    docker run --rm -v "$dest":/repo alpine/git clone "$url" /repo
  fi
  ok "cloned"
}

# Scaffold projects/<name>/{home,repo}, seed home/, set git identity, optional clone.
#   usage: init <project> [git-repo-url]
cmd_init() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 init <project> [git-repo-url]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  local git_url="${2:-}"

  local pdir; pdir="$(project_dir "$name")"
  log "Initialising project '$name' at $pdir"
  mkdir -p "$pdir/home" "$pdir/repo"

  # Seed home from the skeleton WITHOUT clobbering existing files.
  if [ -d "$HOME_SKEL" ]; then
    cp -Rn "$HOME_SKEL/." "$pdir/home/" 2>/dev/null || true
  fi

  # SSH needs strict perms or ssh/git refuse the keys.
  mkdir -p "$pdir/home/.ssh"
  chmod 700 "$pdir/home/.ssh"
  find "$pdir/home/.ssh" -type f -exec chmod 600 {} \; 2>/dev/null || true

  # Git identity (prompted) + optional repo clone.
  configure_git_identity "$pdir"
  [ -n "$git_url" ] && clone_repo "$git_url" "$pdir/repo"

  ok "Project '$name' ready"
  echo "   home → /home/$APP_USER  ($pdir/home  — drop SSH keys in home/.ssh)"
  echo "   repo → /app             ($pdir/repo)"
}

# Auto-scaffold a project if missing.
ensure_project() {
  local name="$1" pdir; pdir="$(project_dir "$name")"
  if [ ! -d "$pdir/home" ] || [ ! -d "$pdir/repo" ]; then
    warn "Project '$name' not initialised — scaffolding it now"
    cmd_init "$name"
  fi
}

# =============================================================================
# build — download all flake deps into the standalone volume
# =============================================================================
cmd_build() {
  require_docker
  [ -f "$FLAKE_DIR/flake.nix" ] || die "no flake.nix in $FLAKE_DIR"
  ensure_volume

  log "Building flake deps '$FLAKE_REF' from $FLAKE_DIR into volume '$NIX_VOLUME' (slow the first time)"

  # Mount:
  #   - the volume at /nix          → the shared store gets populated here
  #   - the flake dir at /flake (rw) → so nix can write/refresh flake.lock
  docker run --rm \
    -v "$NIX_VOLUME":/nix \
    -v "$FLAKE_DIR":/flake \
    -w /flake \
    -e NIX_CONFIG=$'experimental-features = nix-command flakes\nmax-jobs = auto' \
    "$BUILDER_IMAGE" \
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
# run — start the basic runtime container for a project, using the shared store
#   usage: run <project> [cmd...]
# =============================================================================
cmd_run() {
  require_docker
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 run <project> [cmd...]"
  shift
  case "$name" in */*|.|..) die "invalid project name: $name";; esac

  volume_exists || die "volume '$NIX_VOLUME' missing — run '$0 build' first"
  store_is_populated || die "shared profile not found in volume — run '$0 build' first"
  ensure_project "$name"

  local pdir; pdir="$(project_dir "$name")"
  [ -f "$ENTRYPOINT_FILE" ] || die "missing entrypoint at $ENTRYPOINT_FILE"

  # Match the in-container app user to the host uid/gid so the bind-mounted
  # repo stays writable on Linux (harmless/permissive on Docker Desktop).
  local host_uid host_gid
  host_uid="$(id -u)"; host_gid="$(id -g)"

  log "Starting project '$name' ($RUNTIME_IMAGE) as user '$APP_USER' — store ro, home → /home/$APP_USER, repo → /app"

  # Mounts:
  #   /nix   (ro)  shared store/profile — runtime must not mutate it
  #   /seed  (ro)  the project home; entrypoint copies it into /home/app
  #   /app         the project repo — writable, and the WORKDIR
  #   entrypoint   creates the app user, fixes perms, starts zsh+starship
  exec docker run --rm -it \
    --name "$CONTAINER_PREFIX-$name" \
    -v "$NIX_VOLUME":/nix:ro \
    -v "$pdir/home":/seed:ro \
    -v "$pdir/repo":/app \
    -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
    -w /app \
    -e PROFILE="$PROFILE" \
    -e APP_USER="$APP_USER" \
    -e APP_UID="$host_uid" \
    -e APP_GID="$host_gid" \
    -e TERM="${TERM:-xterm-256color}" \
    -e SHELL="$PROFILE/bin/zsh" \
    "$RUNTIME_IMAGE" \
    sh /usr/local/bin/nixenv-entrypoint "$@"
}

# =============================================================================
# projects — list initialised projects
# =============================================================================
cmd_projects() {
  if [ -d "$PROJECTS_DIR" ] && [ -n "$(ls -A "$PROJECTS_DIR" 2>/dev/null)" ]; then
    log "Projects in $PROJECTS_DIR:"
    for d in "$PROJECTS_DIR"/*/; do
      [ -d "$d" ] || continue
      printf '   • %s\n' "$(basename "$d")"
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
  require_docker
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
# shell — alias for `run <project>` with an interactive shell
# =============================================================================
cmd_shell() { cmd_run "$@"; }

# =============================================================================
# update — refresh flake.lock then rebuild into the volume
# =============================================================================
cmd_update() {
  require_docker
  [ -f "$FLAKE_DIR/flake.nix" ] || die "no flake.nix in $FLAKE_DIR"
  log "Updating flake.lock in $FLAKE_DIR"
  docker run --rm \
    -v "$FLAKE_DIR":/flake -w /flake \
    -e NIX_CONFIG=$'experimental-features = nix-command flakes' \
    "$BUILDER_IMAGE" nix flake update
  cmd_build
}

# =============================================================================
# status — show context + volume + profile state
# =============================================================================
cmd_status() {
  ok "Context materialised at $CONTEXT_DIR"
  require_docker
  if volume_exists; then
    ok "Volume '$NIX_VOLUME' exists"
    docker volume inspect "$NIX_VOLUME" --format '   mountpoint: {{.Mountpoint}}'
    local size
    size=$(docker run --rm -v "$NIX_VOLUME":/nix "$BUILDER_IMAGE" du -sh /nix 2>/dev/null | cut -f1 || echo '?')
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
  require_docker
  volume_exists || { warn "Volume '$NIX_VOLUME' does not exist"; return 0; }
  read -r -p "Remove volume '$NIX_VOLUME' and all shared packages? [y/N] " ans
  case "$ans" in
    [yY]*) docker volume rm "$NIX_VOLUME" >/dev/null && ok "Removed volume '$NIX_VOLUME'";;
    *) warn "Aborted";;
  esac
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
  init <project> [git-url]  Scaffold <project>/{home,repo}; prompts for git
                            name/email; clones git-url into repo/ if given
  run <project> [cmd...]    Start the runtime container for a project
                            (no cmd → interactive shared zsh)
  up <project> [cmd...]     build if needed, then run the project
  shell <project>           Alias for 'run <project>' (interactive shell)
  projects                  List initialised projects
  update                    Refresh flake.lock, then rebuild into the volume
  status                    Show context + volume + shared-profile state
  clean                     Delete the standalone volume (removes shared packages)

Per-project mounts (runtime runs as non-root user '$APP_USER'):
  <project>/home → copied into /home/$APP_USER (.ssh, .zshrc, configs)
  <project>/repo → /app  (your code; WORKDIR)

Environment overrides:
  CONTEXT_DIR=$CONTEXT_DIR
  NIX_VOLUME=$NIX_VOLUME
  BUILDER_IMAGE=$BUILDER_IMAGE
  RUNTIME_IMAGE=$RUNTIME_IMAGE
  FLAKE_DIR=$FLAKE_DIR
  FLAKE_REF=$FLAKE_REF
  PROFILE=$PROFILE
  PROJECTS_DIR=$PROJECTS_DIR
  APP_USER=$APP_USER

Examples:
  $0 build                                  # populate the volume once
  $0 init myapp                             # scaffold + prompt for git identity
  $0 init myapp git@github.com:me/app.git   # also clone the repo into repo/
  $0 run myapp                              # dev shell, repo mounted at /app
  $0 run myapp node --version               # run a shared tool directly
  $0 up myapp                               # build (first time) + shell

Skip the git prompt by exporting GIT_USER_NAME / GIT_USER_EMAIL before init.
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    ""|-h|--help|help) usage; return 0;;
  esac

  # Always (re)materialise the embedded context first, then run from it.
  materialize_context

  case "$cmd" in
    build)    cmd_build "$@";;
    init)     cmd_init "$@";;
    run)      cmd_run "$@";;
    up)       cmd_up "$@";;
    shell)    cmd_shell "$@";;
    projects) cmd_projects "$@";;
    update)   cmd_update "$@";;
    status)   cmd_status "$@";;
    clean)    cmd_clean "$@";;
    *) die "unknown command: $cmd (try '$0 --help')";;
  esac
}

main "$@"
