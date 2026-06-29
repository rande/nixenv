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
        let pkgs = pkgsFor system;
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

              # A harmless placeholder so the env is non-empty and builds even
              # before you add anything. Remove once you add real deps.
              pkgs.hello

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
