# =============================================================================
# Per-project flake template (for use INSIDE a project's git repository)
# =============================================================================
# WHAT THIS FILE IS
# -----------------
# Copy this file to the root of a project repo as `flake.nix`. It declares the
# EXTRA tooling that THIS project needs, on top of a shared base toolchain.
#
# It is consumed by `nixenv` (the local container dev-environment tool):
#
#   nixenv build <project>          # builds this flake into the project's profile
#   nixenv init <project> <url> --build
#
# HOW NIXENV USES IT (important context for an LLM editing this file)
# ------------------------------------------------------------------
#   * Every project container already has a SHARED base toolchain on PATH
#     (git, zsh, ripgrep, fd, jq, tmux, zellij, Node, Go, Rust, PHP, Python, uv,
#     the Claude CLI, …). Do NOT re-declare those here — only add what's missing.
#   * `nixenv build <project>` extracts THIS `flake.nix` (and `flake.lock`) from
#     the project's code volume, then runs roughly:
#         nix profile install path:/flake#default \
#           --profile /nix/var/nix/profiles/proj-<project>
#     i.e. it installs the output attribute `packages.<system>.default`.
#   * That per-project profile is mounted read-only and put on PATH *ahead of*
#     the base profile, so the container sees: base tools ∪ these extras, and an
#     entry here can SHADOW a base tool (e.g. pin a different Node version).
#   * Everything is built into ONE shared Nix store, so any package that already
#     exists (from the base or another project) is reused, not rebuilt.
#
# RULES / CONSTRAINTS (an LLM must respect these)
# -----------------------------------------------
#   1. The default output MUST be `packages.<system>.default` and MUST be a
#      single derivation that yields a `bin/` (a `pkgs.buildEnv` is ideal).
#      (The attribute name can be changed via the env var PROJECT_ATTR, but
#      `default` is the convention — keep it unless told otherwise.)
#   2. Pin `nixpkgs` to the SAME channel the base uses (currently
#      `nixos-26.05`). Matching it means packages are shared in the store and
#      versions stay consistent. A different pin still works but downloads a
#      second nixpkgs and dedupes less.
#   3. Only the flake files (`flake.nix` + `flake.lock`) are extracted from the
#      repo at build time. Therefore this flake MUST be self-contained: do NOT
#      reference other local files in the repo (no `./overlays/x.nix`, no
#      `src = ./.`, no building the project itself). Declare DEPENDENCIES only.
#   4. Target Linux systems only — the build runs inside a Linux container.
#   5. Commit `flake.lock` for reproducible builds (run `nix flake lock`).
#
# This flake is also a normal flake: developers can use it directly on a host
# with Nix via `nix build` / `nix develop` (see the devShell at the bottom).
# =============================================================================

{
  description = "Project-specific dev dependencies (layered on the nixenv base toolchain)";

  inputs = {
    # Keep this pin equal to the nixenv base toolchain (nixos-26.05) so the
    # shared Nix store is reused and tool versions line up.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # OPTIONAL: a second input for bleeding-edge tools not yet in the stable
    # channel. Uncomment and use `unstable.<pkg>` in `paths` below if needed.
    # nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      # Containers run on Linux; cover both common CPU arches so the flake
      # builds whether the host is x86_64 or Apple-silicon/ARM.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Per-system nixpkgs instance. `allowUnfree = true` mirrors the base so
      # unfree packages (if you need any) evaluate; drop it if you prefer.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # -----------------------------------------------------------------------
      # packages.<system>.default — THIS is what `nixenv build <project>`
      # installs into the project's profile. It must produce a `bin/`.
      #
      # `buildEnv` merges several packages into a single environment whose `bin`
      # is what ends up on PATH. Add the project's extra tools to `paths`.
      # Remember: base tools are already available — list only what's missing or
      # what you want to pin to a specific version.
      # -----------------------------------------------------------------------
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # --- Custom /etc/hosts entries (optional) ---------------------------
          # nixenv merges a file shipped by this profile at etc/hosts.extra into
          # the container's /etc/hosts on every start. Declare the entries here in
          # native /etc/hosts format ("<ip><TAB or spaces><name>"), one per line.
          # `writeTextDir` produces a derivation containing exactly
          # $out/etc/hosts.extra, which buildEnv (below) merges into the profile.
          # Leave the list empty (or drop `hostsExtra` from `paths`) for none.
          hostsExtra = pkgs.writeTextDir "etc/hosts.extra" ''
            10.0.0.5      db
            10.0.0.6      cache.internal
            127.0.0.1     api.local
          '';

          # --- Startup hook (optional) ----------------------------------------
          # DECLARED here at build time, EXECUTED at container start: nixenv
          # SOURCES etc/nixenv-hooks.sh from this profile before any service
          # (incl. sshd) starts. This is the only way to run project code at
          # startup — a Nix build is sandboxed to its own $out and can never
          # write $HOME. The hook runs in the real container, as the app user,
          # with this profile already first on PATH.
          # Handy variables: $SVROOT ($HOME/.nixenv-sv), $NIXENV_APP_MOUNT,
          # $NIXENV_PROJECT, $NIXENV_EXTRA_PROFILE.
          # Anything it writes into $SVROOT/<name>/run is supervised THIS boot.
          #
          # Simplest form — the file is sourced, so top-level code just runs.
          # A <project>-setup script shipped by this same flake is on PATH:
          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            myproject-setup
          '';
          # Equivalent using the optional hook FUNCTION instead. Use this form if
          # you want a repo/home hook to be able to override it (last definition
          # wins), or if the body needs `return` — never `exit` at top level,
          # which would terminate the entrypoint:
          #
          #   startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" '''
          #     nixenv_pre_ssh_start() {
          #       mkdir -p "$SVROOT/supervisord"
          #       install -Dm755 ${"\${supervisordRun}"}/bin/run "$SVROOT/supervisord/run"
          #     }
          #   ''';
        in {
          default = pkgs.buildEnv {
            name = "project-deps";

            # Pull in man pages too (skip "doc" — some packages fail to build it).
            extraOutputsToInstall = [ "man" ];

            # >>> EDIT THIS LIST <<<  — the project's extra dependencies.
            # These are EXAMPLES; replace with what your project actually needs.
            paths = with pkgs; [
              # --- Example: pin a specific language runtime (shadows the base) ---
              # nodejs_22            # base already provides Node 22; override here if needed

              # --- Example: databases / infra clients ---
              # postgresql_16        # provides psql, pg_dump, …
              # redis                # redis-cli
              # awscli2
              # terraform
              # kubectl

              # --- Example: project build tools / linters ---
              # gnumake
              # shellcheck
              # hadolint

              # --- Example: a process supervisor to run at container startup ---
              # python3Packages.supervisor   # provides `supervisord` / `supervisorctl`
              #   (see "RUNNING SERVICES AT STARTUP" at the bottom of this file)

              # A harmless placeholder so the env is non-empty and builds even
              # before you add anything. Remove once you add real deps.
              pkgs.hello

              # --- Custom /etc/hosts entries (see `hostsExtra` above) ---
              # Ships etc/hosts.extra in the profile; nixenv merges it into the
              # container's /etc/hosts at start. Remove this line to disable.
              hostsExtra

              # --- Startup hook (see `startupHook` above) ---
              # Ships etc/nixenv-hooks.sh; nixenv sources it and calls
              # nixenv_pre_ssh_start before services start. Remove to disable.
              startupHook

              # --- Example using the optional unstable input (see inputs above) ---
              # unstable.some-bleeding-edge-tool
            ];
          };
        });

      # -----------------------------------------------------------------------
      # devShells.default — OPTIONAL, for developers running this flake directly
      # on a host with Nix (`nix develop`). nixenv does NOT use this; it only
      # installs `packages.<system>.default`. Kept in sync for convenience.
      # -----------------------------------------------------------------------
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = [ self.packages.${system}.default ];
          };
        });
    };
}

# =============================================================================
# RUNNING SERVICES AT STARTUP (runit) — e.g. supervisord
# =============================================================================
# This flake only puts tools on PATH. To actually RUN a process when the project
# container starts, add a runit service to your repo. nixenv supervises sshd via
# `runit`, and at boot it picks up any service you define at:
#
#     <repo>/.nixenv/sv/<name>/run        (an executable shell script)
#
# Each `run` must exec a FOREGROUND (non-daemonising) process — runit restarts it
# if it exits. The service runs as your container user, with this flake's tools
# (and the base toolchain) on PATH.
#
# ── Example: run supervisord ────────────────────────────────────────────────
# 1. Add the package above:   python3Packages.supervisor
# 2. Create an executable run script in the repo:
#
#      mkdir -p .nixenv/sv/supervisord
#      cat > .nixenv/sv/supervisord/run <<'SH'
#      #!/bin/sh
#      exec supervisord -n -c /app/supervisord.conf
#      SH
#      chmod +x .nixenv/sv/supervisord/run
#
#    (`-n` keeps supervisord in the foreground so runit can supervise it.)
# 3. Commit your supervisord.conf at the repo root (it's mounted at /app).
# 4. Build + (re)start the project:
#
#      nixenv build <project>      # so `supervisord` is on PATH
#      nixenv stop <project> && nixenv run <project>
#
# Then `supervisorctl` (also on PATH) manages your supervisord-defined processes.
# Add more services the same way: one <repo>/.nixenv/sv/<name>/run per service.
#
# ── Alternative: declare the service from THIS flake ────────────────────────
# A flake build is sandboxed — it can only write to its own $out in the store,
# so it can NEVER create files in $HOME (e.g. ~/.nixenv-sv/<name>/run) or in the
# app volume. To ship a service with the toolchain instead of the repo, use the
# STARTUP HOOK (`startupHook` above): the flake declares etc/nixenv-hooks.sh at
# build time, and nixenv calls `nixenv_pre_ssh_start` at container start — in
# the real container, where writing to $HOME works. Services it creates in
# $SVROOT are supervised in the same boot.
# =============================================================================

# =============================================================================
# PER-PROJECT HOME OVERRIDES (<repo>/.nixenv/home/)
# =============================================================================
# The container's home (dotfiles: nvim, zsh, git, tmux, ssh config) comes from a
# shared skeleton baked into nixenv. To customise it FOR THIS PROJECT, commit
# files under <repo>/.nixenv/home/ mirroring their path in $HOME, e.g.:
#
#     .nixenv/home/.config/nvim/lua/plugins/extra.lua
#     .nixenv/home/.zshrc                    # replaces the shared .zshrc
#
# Apply them into the project's home volume with:
#
#     nixenv sync-home <project>
#
# sync-home lays down the shared skeleton first, then these overrides on top
# (yours win). It backs up any file it overwrites to
# ~/.nixenv/home-backups/<timestamp> in the volume, and never touches installed
# nvim plugins, shell history, or your git credentials. Re-run it whenever you
# change these files or nixenv ships new defaults.
# =============================================================================

# =============================================================================
# CUSTOM /etc/hosts ENTRIES (declared in this flake — see `hostsExtra` above)
# =============================================================================
# The container's /etc/hosts is non-root and engine-managed, so you can't edit it
# in place. Instead nixenv rebuilds it at every container start from base entries
# plus a file this flake ships in its profile: etc/hosts.extra.
#
# Declare the entries with `pkgs.writeTextDir "etc/hosts.extra" ''…''` (native
# /etc/hosts format) and add the result to `buildEnv.paths` — both already shown
# above. Then build + restart to apply:
#
#     nixenv build <project>
#     nixenv stop <project> && nixenv run <project>
#     getent hosts db          # -> 10.0.0.5  db
#
# Precedence: base localhost lines + "127.0.1.1 <hostname>", then this flake's
# etc/hosts.extra, then the host-side ~/.nixenv/projects/<project>/hosts.extra
# (a local-only override you can also manage with `nixenv host <project> …`).
# Committing the entries here keeps them versioned and shared with your team.
# =============================================================================
