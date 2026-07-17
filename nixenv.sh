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
NIX_VOLUME="${NIX_VOLUME:-nixenv__nixos_store}"      # standalone Docker volume for /nix
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
          # create. fetchTarball has no pinned hash, so the build runs --impure.
          # Bump zmxVersion to upgrade.
          zmxVersion = "0.6.0";
          zmxArch = if system == "aarch64-linux" then "aarch64" else "x86_64";
          zmxSrc = builtins.fetchTarball
            "https://zmx.sh/a/zmx-${zmxVersion}-linux-${zmxArch}.tar.gz";
          zmxPkg = pkgs.runCommand "zmx-${zmxVersion}" { } ''
            bin=$(find ${zmxSrc} -type f -name zmx | head -n1)
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

              # ── Languages & runtimes ───────────────────────────────────────
              nodejs_22
              go
              rustup
              php85
              php85Packages.composer
              python312
              uv
              sqlite

              # ── Build tools (compile native deps: node-gyp, wheels, etc.) ──
              gnumake
              gcc
              binutils
              pkg-config
              cmake
              autoconf
              automake
              libtool

              # ── Editor: Neovim (AstroNvim) + language servers ──────────────
              neovim
              tree-sitter          # parser generator AstroNvim uses
              lua-language-server  # for editing the nvim config itself
              gopls                          # Go
              (lib.hiPrio rust-analyzer)     # Rust (win the bin/rust-analyzer collision with rustup)
              pyright                        # Python
              typescript                     # TypeScript runtime
              typescript-language-server     # TypeScript/JavaScript
              bash-language-server           # Bash
              intelephense                   # PHP
              ruby-lsp                       # Ruby

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

mkdir -p "$HOME_DIR/.cache/omz" "$HOME_DIR/.ssh" 2>/dev/null || true
chmod 700 "$HOME_DIR/.ssh" 2>/dev/null || true

# --- Shared profile + shell config available to every zsh --------------------
# .zshenv is sourced for login and non-login shells alike. $PROFILE etc. are
# baked in at write time; \$HOME / \$NIXENV_* stay literal for zsh to evaluate.
cat > "$HOME_DIR/.zshenv" <<EOF
export PROFILE="$PROFILE"
export NIXENV_PROJECT="${NIXENV_PROJECT:-}"
export NIXENV_EXTRA_PROFILE="${NIXENV_EXTRA_PROFILE:-}"
# The per-project profile (extra tooling) goes first when it exists, then base.
_nixenv_extra=""
[ -n "\$NIXENV_EXTRA_PROFILE" ] && [ -d "\$NIXENV_EXTRA_PROFILE/bin" ] && _nixenv_extra="\$NIXENV_EXTRA_PROFILE/bin:"
export PATH="\${_nixenv_extra}$PROFILE/bin:\$HOME/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export ZSH="$PROFILE/share/oh-my-zsh"
export ZSH_CACHE_DIR="\$HOME/.cache/omz"
export SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt"
export NIX_SSL_CERT_FILE="$PROFILE/etc/ssl/certs/ca-bundle.crt"
export EDITOR=vim
export LANG=C.UTF-8
EOF

# =============================================================================
# Command mode: run the given command as the (already non-root) user, then exit.
# =============================================================================
if [ "$#" -gt 0 ]; then
  export PATH="$PROFILE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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

# Host keys in the writable HOME.
for t in ed25519 rsa; do
  f="$HOME_DIR/.ssh/ssh_host_${t}_key"
  [ -f "$f" ] || "$SSHKEYGEN" -t "$t" -f "$f" -N "" -q
done

# Build authorized_keys from any *.pub the project provided (optional — login is
# open via the empty-password 'none' method too).
if [ ! -f "$HOME_DIR/.ssh/authorized_keys" ]; then
  for pub in "$HOME_DIR"/.ssh/*.pub; do
    [ -f "$pub" ] || continue
    cat "$pub" >> "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null || true
  done
fi

SFTP="$(ls "$PROFILE"/libexec/sftp-server 2>/dev/null || ls "$PROFILE"/libexec/openssh/sftp-server 2>/dev/null || true)"

{
  echo "Port $SSHD_PORT"
  echo "HostKey $HOME_DIR/.ssh/ssh_host_ed25519_key"
  echo "HostKey $HOME_DIR/.ssh/ssh_host_rsa_key"
  echo "PidFile $SSHRUN/sshd.pid"
  echo "PermitRootLogin no"
  # Open local-dev login: no key and no password. The app account has an empty
  # password (mounted /etc/shadow) and sshd permits empty passwords, so the SSH
  # 'none' method succeeds. Pubkey still works if keys are present.
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication yes"
  echo "PermitEmptyPasswords yes"
  echo "KbdInteractiveAuthentication no"
  echo "AuthorizedKeysFile .ssh/authorized_keys"
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
# A project can ship runit services in its repo at /app/.nixenv/sv/<name>/run
# (an executable run script that exec's a FOREGROUND process). Each is wrapped
# into a supervised service that runs as this user, next to sshd. Example for
# supervisord: /app/.nixenv/sv/supervisord/run containing
#   #!/bin/sh
#   exec supervisord -n -c /app/supervisord.conf
project_services=""
if [ -d /app/.nixenv/sv ]; then
  for d in /app/.nixenv/sv/*/; do
    [ -f "${d}run" ] || continue
    sname="$(basename "$d")"
    mkdir -p "$SVROOT/$sname"
    cp "${d}run" "$SVROOT/$sname/run" && chmod +x "$SVROOT/$sname/run"
    project_services="$project_services $sname"
  done
fi

# PATH for all services: project profile (extra tooling) first, then base, so a
# service can use tools from the project flake (e.g. supervisord) or the base.
_extra=""
[ -n "${NIXENV_EXTRA_PROFILE:-}" ] && [ -d "$NIXENV_EXTRA_PROFILE/bin" ] && _extra="$NIXENV_EXTRA_PROFILE/bin:"
export PATH="${_extra}$PROFILE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "nixenv: unprivileged sshd ready on :$SSHD_PORT as '$APP_USER' (no key/password)"
[ -n "$project_services" ] && echo "nixenv: project services:$project_services"

# runsvdir would be the natural multi-service supervisor, but in this container
# it can't locate its runsv children — so we start each extra service under its
# own runsv (background) and keep sshd's runsv as PID 1.
for s in $project_services; do
  "$RUNSV" "$SVROOT/$s" &
done
exec "$RUNSV" "$SVROOT/sshd"
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
  -- Core: AstroNvim v4
  {
    "AstroNvim/AstroNvim",
    version = "^4",
    import = "astronvim.plugins",
    opts = {
      mapleader = " ",
      maplocalleader = ",",
      icons_enabled = true,
    },
  },

  -- Community: language packs for the requested languages
  "AstroNvim/astrocommunity",
  { import = "astrocommunity.pack.go" },
  { import = "astrocommunity.pack.typescript" },
  { import = "astrocommunity.pack.python" },
  { import = "astrocommunity.pack.rust" },
  { import = "astrocommunity.pack.php" },
  { import = "astrocommunity.pack.ruby" },
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
}

# Rootless podman remaps uids; --userns=keep-id makes the container see your real
# host uid (so bind-mounted files stay writable). No-op for docker.
engine_userns() {
  [ "$ENGINE" = podman ] && printf '%s' "--userns=keep-id"
}

# --privileged for the nix builder so source builds using bwrap/user namespaces
# (e.g. zmx) work inside the builder container. No-op when disabled.
builder_priv() {
  [ "$BUILDER_PRIVILEGED" = 1 ] && printf '%s' "--privileged"
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
project_dir()     { printf '%s/%s' "$PROJECTS_DIR" "$1"; }
app_volume()      { printf '%s_%s_app'  "$CONTAINER_PREFIX" "$1"; }   # e.g. nixenv_wealth_app       → /app
home_volume()     { printf '%s_%s_home' "$CONTAINER_PREFIX" "$1"; }   # e.g. nixenv_wealth_home      → /home/app
db_volume()       { printf '%s_%s_databases' "$CONTAINER_PREFIX" "$1"; } # e.g. nixenv_wealth_databases → /databases
project_profile() { printf '/nix/var/nix/profiles/proj-%s' "$1"; }   # per-project extra tooling
vol_exists()      { "$ENGINE" volume inspect "$1" >/dev/null 2>&1; }

# Ensure the project's /app and /home volumes exist and are OWNED BY OUR UID, so
# the non-root runtime container can write them. Named volumes start root-owned;
# we create them and chown via a one-time throwaway root helper container (only
# the running container is non-root). A freshly-created home volume is seeded
# from the host seed dir (<project>/home: skeleton + git identity/credentials).
ensure_volumes() {
  local name="$1" uid gid appv homev dbv hf=0 fresh_mounts="" fresh_paths=""
  uid="$(id -u)"; gid="$(id -g)"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"; dbv="$(db_volume "$name")"

  # Create ONLY missing volumes. Existing volumes (with their data) are left
  # completely alone — not even mounted by the chown helper below.
  if ! vol_exists "$appv";  then "$ENGINE" volume create "$appv"  >/dev/null; fresh_mounts="$fresh_mounts -v $appv:/app";          fresh_paths="$fresh_paths /app"; fi
  if ! vol_exists "$homev"; then "$ENGINE" volume create "$homev" >/dev/null; fresh_mounts="$fresh_mounts -v $homev:/home";        fresh_paths="$fresh_paths /home"; hf=1; fi
  if ! vol_exists "$dbv";   then "$ENGINE" volume create "$dbv"   >/dev/null; fresh_mounts="$fresh_mounts -v $dbv:/databases";     fresh_paths="$fresh_paths /databases"; fi

  # chown ONLY the just-created volumes to our uid so the non-root container can
  # write them (named volumes start root-owned). Never touches existing ones.
  if [ -n "$fresh_paths" ]; then
    log "Preparing ownership of new volume(s):$fresh_paths (uid $uid:$gid)"
    "$ENGINE" rm -f "${CONTAINER_PREFIX}__chown-$name" >/dev/null 2>&1 || true
    "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__chown-$name" -u 0 $fresh_mounts \
      "$(img "$RUNTIME_IMAGE")" chown -R "$uid:$gid" $fresh_paths >/dev/null 2>&1 \
      || warn "chown helper failed — a new volume may be unwritable by uid $uid"
  fi

  if [ "$hf" = 1 ] && [ -d "$(project_dir "$name")/home" ]; then
    log "Seeding home volume '$homev' from $(project_dir "$name")/home"
    "$ENGINE" rm -f "${CONTAINER_PREFIX}__seed-$name" >/dev/null 2>&1 || true
    "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__seed-$name" --user "$uid:$gid" $(engine_userns) \
      -v "$(project_dir "$name")/home":/seed:ro -v "$homev":/home \
      "$(img "$RUNTIME_IMAGE")" \
      sh -c 'cp -a /seed/. /home/ 2>/dev/null || cp -R /seed/. /home/ 2>/dev/null || true' \
      >/dev/null 2>&1 || true
  fi
}

# Generate the /etc/passwd, /etc/group, /etc/shadow that the container runs with.
# The container runs as the host uid/gid; these files give that id the name
# 'app' (home /home/app, shell = shared zsh) and an EMPTY password so the open
# SSH 'none' method works. They are bind-mounted read-only into the container.
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
$APP_USER::19000:0:99999:7:::
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
write_host_ssh_config() {
  local name="$1" port pdir sd
  port="$(project_port "$name")"
  pdir="$(project_dir "$name")"; sd="$pdir/ssh"
  mkdir -p "$sd"
  [ -f "$sd/config" ] && return 0
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
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    RequestTTY yes
    RemoteCommand $PROFILE/bin/zmx attach %k
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
EOF
  ok "wrote host ssh config: $sd/config"
}

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

# Clone a git repo into the project's repo dir (must be empty). Runs the debian
# runtime image as the non-root user with the shared store + project home, so it
# uses the store's git and the project's SSH keys; the bind-mounted repo dir ends
# up owned by your host uid.
clone_repo() {
  local url="$1" name="$2"
  require_engine
  local pdir appv homev; pdir="$(project_dir "$name")"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"

  if ! store_is_populated; then
    warn "shared store not built yet — skipping clone"
    warn "run '$0 build', then '$0 init $name $url' to clone"
    return 0
  fi
  ensure_volumes "$name"
  if [ -n "$("$ENGINE" run --rm -v "$appv":/app "$(img "$RUNTIME_IMAGE")" sh -c 'ls -A /app' 2>/dev/null)" ]; then
    warn "app volume '$appv' not empty — skipping clone"
    return 0
  fi

  write_passwd_files "$pdir"
  log "Cloning $url → volume '$appv' via $RUNTIME_IMAGE + shared git"
  "$ENGINE" run --rm \
    --user "$(id -u):$(id -g)" \
    $(engine_userns) \
    -v "$NIX_VOLUME":/nix:ro \
    -v "$homev":/home/"$APP_USER" \
    -v "$appv":/app \
    -v "$pdir/passwd":/etc/passwd:ro \
    -v "$pdir/group":/etc/group:ro \
    -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
    -w /app \
    -e HOME=/home/"$APP_USER" \
    -e PROFILE="$PROFILE" \
    -e APP_USER="$APP_USER" \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
    "$(img "$RUNTIME_IMAGE")" \
    sh /usr/local/bin/nixenv-entrypoint git clone "$url" /app
  ok "cloned into volume '$appv'"
}

# Scaffold <name>/home + app volume, seed home/, set git identity, optional clone.
#   usage: init <project> [git-repo-url]
cmd_init() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: $0 init <project> [git-repo-url] [--build]"
  case "$name" in */*|.|..) die "invalid project name: $name";; esac
  shift

  local git_url="" do_build=0 a
  for a in "$@"; do
    case "$a" in
      --build) do_build=1;;
      --*) die "unknown option: $a (usage: $0 init <project> [git-repo-url] [--build])";;
      *) [ -z "$git_url" ] && git_url="$a" || die "unexpected argument: $a";;
    esac
  done

  local pdir; pdir="$(project_dir "$name")"
  log "Initialising project '$name' at $pdir"
  mkdir -p "$pdir/home"   # host seed for the home volume (skeleton + git config)

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

  # Assign a stable random SSH port + write the host-side ssh config.
  local port; port="$(project_port "$name")"
  write_host_ssh_config "$name"

  ok "Project '$name' ready"
  echo "   home → /home/$APP_USER  (volume $(home_volume "$name"); seed: $pdir/home)"
  echo "   repo → /app             (volume $(app_volume "$name"))"
  echo "   db   → /databases       (volume $(db_volume "$name"))"
  echo "   ssh  → host port $port  (connects as '$APP_USER', no key/password)"
  echo "   alias→ ssh $name        (after: $0 ssh-config --install)"

  # --build: also build the project's own flake (if the repo has one).
  [ "$do_build" = 1 ] && cmd_build_project "$name"
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
  # `build <project>` builds the project's own flake; `build` builds the base.
  if [ -n "${1:-}" ]; then cmd_build_project "$@"; return $?; fi

  require_engine
  [ -f "$FLAKE_DIR/flake.nix" ] || die "no flake.nix in $FLAKE_DIR"
  ensure_volume

  log "Building flake deps '$FLAKE_REF' from $FLAKE_DIR into volume '$NIX_VOLUME' (slow the first time)"

  # Mount:
  #   - the volume at /nix          → the shared store gets populated here
  #   - the flake dir at /flake (rw) → so nix can write/refresh flake.lock
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__build" >/dev/null 2>&1 || true
  "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__build" \
    $(builder_priv) \
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
      # so the runtime container sees them. --impure: zmx uses fetchTarball
      # (prebuilt binary) with no pinned hash.
      nix profile install "'"$FLAKE_REF"'" \
        --profile "'"$PROFILE"'" \
        --impure \
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

  local dir="" a
  for a in "$@"; do
    case "$a" in
      --dir=*) dir="${a#--dir=}";;
      --dir)   die "use --dir=<path>";;
      *) die "unknown option: $a (usage: $0 build <project> [--dir=<path>])";;
    esac
  done

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
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__build-$name" >/dev/null 2>&1 || true
  "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__build-$name" \
    -v "$NIX_VOLUME":/nix \
    -v "$fdir":/flake \
    -w /flake \
    -e NIX_CONFIG=$'experimental-features = nix-command flakes\nmax-jobs = auto' \
    "$(img "$BUILDER_IMAGE")" \
    sh -euc '
      mkdir -p /nix/var/nix/profiles
      echo "--- resetting project profile ---"
      rm -f "'"$prof"'" "'"$prof"'"-*-link 2>/dev/null || true
      echo "--- nix profile install (project extras) ---"
      nix profile install "path:/flake#'"$PROJECT_ATTR"'" \
        --profile "'"$prof"'" \
        --accept-flake-config \
        --print-build-logs
      nix store optimise || true
      echo "--- project tooling on PATH ---"
      ls -1 "'"$prof"'/bin" 2>/dev/null | head -n 40 || true
    '

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
  [ -n "$name" ] || die "usage: $0 run <project> [cmd...]"
  shift
  case "$name" in */*|.|..) die "invalid project name: $name";; esac

  volume_exists || die "volume '$NIX_VOLUME' missing — run '$0 build' first"
  store_is_populated || die "shared profile not found in volume — run '$0 build' first"
  ensure_project "$name"

  local pdir cname appv homev dbv; pdir="$(project_dir "$name")"
  cname="$(container_name "$name")"
  appv="$(app_volume "$name")"; homev="$(home_volume "$name")"; dbv="$(db_volume "$name")"
  [ -f "$ENTRYPOINT_FILE" ] || die "missing entrypoint at $ENTRYPOINT_FILE"
  [ "$#" -eq 0 ] || die "run takes no command — use '$0 shell $name' or '$0 ssh $name'"

  mkdir -p "$pdir/home/.ssh"
  ensure_volumes "$name"        # create + chown (+ seed home) the app/home volumes
  prepare_claude_share          # shared Claude creds + global config, mounted rw
  write_passwd_files "$pdir"    # /etc/passwd|group|shadow giving our uid the name 'app'
  write_host_ssh_config "$name" # <project>/ssh/config for `ssh <project>`

  # --- Start a detached container: unprivileged sshd under runit -------------
  local port; port="$(project_port "$name")"

  # Published ports: ssh (loopback) → in-container $SSHD_PORT, + <project>/ports.
  # Each ports line: "8080" → 127.0.0.1:8080:8080, or a full spec like
  # "3000:3000", "0.0.0.0:8080:80", "127.0.0.1:5173:5173".
  local pub; pub=(-p "127.0.0.1:$port:$SSHD_PORT")
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
    log "Starting service '$cname' ($RUNTIME_IMAGE) as uid $(id -u) — sshd on 127.0.0.1:$port, volumes $appv → /app, $homev → /home/$APP_USER"
    "$ENGINE" run -d \
      --name "$cname" \
      --hostname "$name" \
      --user "$(id -u):$(id -g)" \
      $(engine_userns) \
      --sysctl net.ipv4.ping_group_range="0 2147483647" \
      "${pub[@]}" \
      -v "$NIX_VOLUME":/nix:ro \
      -v "$homev":/home/"$APP_USER" \
      -v "$appv":/app \
      -v "$dbv":/databases \
      -v "$pdir/passwd":/etc/passwd:ro \
      -v "$pdir/group":/etc/group:ro \
      -v "$pdir/shadow":/etc/shadow:ro \
      -v "$CLAUDE_DIR":/home/"$APP_USER"/.claude \
      -v "$CLAUDE_JSON":/home/"$APP_USER"/.claude.json \
      -v "$ENTRYPOINT_FILE":/usr/local/bin/nixenv-entrypoint:ro \
      -w /app \
      -e HOME=/home/"$APP_USER" \
      -e PROFILE="$PROFILE" \
      -e APP_USER="$APP_USER" \
      -e SSHD_PORT="$SSHD_PORT" \
      -e NIXENV_PROJECT="$name" \
      -e NIXENV_EXTRA_PROFILE="$(project_profile "$name")" \
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

  # No -u: the container already runs as our uid, so exec inherits it. (Passing
  # -u app would need 'app' resolvable in the daemon's view of /etc/passwd, which
  # a bind-mounted passwd isn't, reliably.)
  exec "$ENGINE" exec -it -w /app \
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
  exec ssh -p "$port" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
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
    echo "    $ENGINE rm -f $cname"
    [ -n "$vols" ] && echo "    $ENGINE volume rm$vols   (code + home volumes)"
    echo "    rm -f $prof*   (its extra-tooling profile, inside the store)"
  else
    warn "no container engine detected — its container/volumes won't be removed"
  fi
  echo "    rm -rf $pdir   (home seed, SSH keys, stored git credentials, port)"
  warn "This cannot be undone (including all code in the app volume)."

  printf 'Proceed? [y/N] '
  local ans=""; read -r ans || true
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *) warn "Aborted — nothing deleted"; return 0 ;;
  esac

  if [ -n "$ENGINE" ]; then
    "$ENGINE" rm -f "$cname" >/dev/null 2>&1 || true
    [ -n "$vols" ] && "$ENGINE" volume rm $vols >/dev/null 2>&1 || true
    volume_exists && "$ENGINE" run --rm -v "$NIX_VOLUME":/nix "$(img "$BUILDER_IMAGE")" \
      sh -c "rm -f '$prof' '$prof'-*-link" >/dev/null 2>&1 || true
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
  "$ENGINE" rm -f "${CONTAINER_PREFIX}__update" >/dev/null 2>&1 || true
  "$ENGINE" run --rm --name "${CONTAINER_PREFIX}__update" \
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
  build <project> [--dir=P] Build the project's OWN flake into a per-project
                            profile, layered on top of the base. Default reads
                            flake.nix from the repo root; --dir=P copies a whole
                            folder (flake.nix + local deps it references)
  init <project> [git-url] [--build]
                            Scaffold <project>/home + the <project>_app volume;
                            prompts for git name/email; clones git-url if given;
                            --build also builds the project's flake
  run <project>             Start the project as a background service (sshd under
                            runit); prints the SSH port
  ssh <project>             SSH into the running service (auto-starts it)
  shell <project>           Interactive zsh via the engine's 'exec' (no SSH key)
  expose <project> <port>…  Publish extra port(s) (e.g. 8080 or 3000:3000),
                            stored in <project>/ports; restarts to apply
  ssh-config [--install]    Print (or install) the ~/.ssh/config Include so
                            'ssh <project>' works via each <project>/ssh/config
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
  volume <project>_home → /home/$APP_USER  (seeded from <project>/home)
  volume <project>_app  → /app             (your code; WORKDIR)
  <project>/home        → host seed for the home volume (.ssh, .zshrc, configs)
  <project>/port        → the project's stable random host SSH port

SSH: each project gets a random host port (stored once in <project>/port). The
container runs an unprivileged sshd (port 2222) via runit as '$APP_USER', open
login (no key/password) on 127.0.0.1. Use 'ssh-config --install' + 'ssh <project>'
for the zmx workflow.

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
    ssh-config) cmd_ssh_config "$@";;
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
