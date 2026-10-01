# =============================================================================
# dev/flake.nix — the project flake for DEVELOPING nixenv inside nixenv
# =============================================================================
#   ./nixenv.sh init nixenv https://github.com/rande/nixenv.git
#   ./dev/engines.sh up nixenv               # Docker + Podman sidecars (host side)
#   ./nixenv.sh build nixenv --dir=dev       # this flake; --dir is remembered
#   ./nixenv.sh run nixenv && ssh nixenv
#
# Lives in dev/, not the repo root: nixenv's own toolchain flake is embedded in
# nixenv.sh, and a root flake.nix would be mistaken for it. See DEVELOPING.md.
#
# WHAT IT ADDS on top of nixenv's base toolchain
#   * `docker` and `podman` clients, pre-wired to the sidecar sockets that
#     dev/engines.sh exposes at /var/run/nixenv — so `./nixenv.sh …` inside this
#     project drives a REAL engine and can boot nested projects;
#   * `nixenv` on PATH = THIS checkout's ./nixenv.sh (the code you're editing);
#   * `nixenv-docker` / `nixenv-podman`: the same, pinned to one engine, each
#     with its own nixenv state, so both can run side by side;
#   * what the test suite and reviews need: python3 (the squid ACL model in
#     tests/), shellcheck, shfmt, jq, gh.
#
# The engines are privileged sidecars, NOT something this flake can start: a
# project container is non-root with every capability dropped, so no daemon can
# run in it. Without the sidecars the wrappers fall through to the plain clients.
# =============================================================================
{
  description = "nixenv development environment (nixenv project flake)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";   # same pin as the base

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      sockDir = "/var/run/nixenv";   # must match ENGINE_SOCK_DIR in dev/engines.sh
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          # Clients that default to the sidecar sockets. An explicit DOCKER_HOST
          # / CONTAINER_HOST still wins. The real clients are referenced, not
          # installed, so their own `docker`/`podman` don't collide with these.
          docker = pkgs.writeShellScriptBin "docker" ''
            if [ -z "''${DOCKER_HOST:-}" ] && [ -S ${sockDir}/docker.sock ]; then
              export DOCKER_HOST=unix://${sockDir}/docker.sock
            fi
            exec ${pkgs.docker-client}/bin/docker "$@"
          '';
          podman = pkgs.writeShellScriptBin "podman" ''
            if [ -z "''${CONTAINER_HOST:-}" ] && [ -S ${sockDir}/podman.sock ]; then
              export CONTAINER_HOST=unix://${sockDir}/podman.sock
            fi
            # The sidecar is a remote service; plain podman would try to run
            # containers itself, which a capability-less container can't.
            if [ -n "''${CONTAINER_HOST:-}" ]; then
              exec ${pkgs.podman}/bin/podman --remote "$@"
            fi
            exec ${pkgs.podman}/bin/podman "$@"
          '';

          # The checkout under development: the repo root is the app volume.
          # (a double-quoted Nix string escapes ${ as \${ — the ''${ form only
          #  works inside indented strings)
          checkout = "\${NIXENV_APP_MOUNT:-/app}/nixenv.sh";
          requireCheckout = ''
            if [ ! -x "${checkout}" ]; then
              echo "nixenv-dev: no executable ${checkout} — is the nixenv repo the app volume?" >&2
              exit 1
            fi
          '';

          # Everything the nested nixenv creates is named nixdev-* / nixdev_*
          # (containers, volumes, networks, store volume), never nixenv-*: if
          # the engine is ever the one running the HOSTED nixenv — a shared
          # docker socket — a nested 'stop' or 'delete' can't reach the hosted
          # containers. An explicit CONTAINER_PREFIX (the test suite's nxt)
          # still wins.
          devPrefix = ''
            export CONTAINER_PREFIX="''${CONTAINER_PREFIX:-nixdev}"
          '';

          # `nixenv` — the LOCAL ./nixenv.sh on PATH, so the checkout you're
          # editing is what runs (never a stale installed copy). Uses ~/.nixenv
          # and the engine remembered in ~/.nixenv/engine.
          nixenv = pkgs.writeShellScriptBin "nixenv" ''
            ${requireCheckout}
            ${devPrefix}
            exec "${checkout}" "$@"
          '';

          # nixenv-docker / nixenv-podman — run THIS checkout's nixenv.sh against
          # one engine, with its own state. nixenv keeps everything under
          # ~/.nixenv (projects, proxy config, squid's pid file, the engine
          # choice); sharing that between two engines would make their proxies
          # fight over the same files. So each gets its own HOME below the real
          # one — still under /home/app, where the sidecars see the same paths.
          nixenvFor = engine: pkgs.writeShellScriptBin "nixenv-${engine}" ''
            ${requireCheckout}
            if [ -z "''${NIXENV_DEV_REAL_HOME:-}" ]; then
              export NIXENV_DEV_REAL_HOME="$HOME"
            fi
            ${devPrefix}
            export CONTAINER_ENGINE=${engine}
            export HOME="$NIXENV_DEV_REAL_HOME/.nixenv-dev/${engine}"
            mkdir -p "$HOME"
            exec "${checkout}" "$@"
          '';

          # Pick the nested nixenv's engine once, so it doesn't prompt when both
          # clients are on PATH. Only if you haven't chosen already; delete
          # ~/.nixenv/engine (or set CONTAINER_ENGINE) to switch.
          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_dev_pick_engine() {
              [ -s "$HOME/.nixenv/engine" ] && return 0
              if [ -S ${sockDir}/docker.sock ]; then e=docker
              elif [ -S ${sockDir}/podman.sock ]; then e=podman
              else return 0
              fi
              mkdir -p "$HOME/.nixenv" && printf '%s\n' "$e" > "$HOME/.nixenv/engine"
            }
            nixenv_dev_pick_engine || true
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "nixenv-dev";
            paths = [
              docker
              podman
              nixenv
              (nixenvFor "docker")
              (nixenvFor "podman")
              pkgs.python3
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.jq
              pkgs.gh
              startupHook
            ];
          };
        });
    };
}
