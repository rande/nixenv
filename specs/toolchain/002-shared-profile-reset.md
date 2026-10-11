---
id: TOOL-02
title: "build switches a profile only after a successful build"
area: toolchain
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/47-nix-build.sh
---

# TOOL-02: build switches a profile only after a successful build

## Rule

- `build` (base) and `build <project>` MUST build the flake first
  (`nix build --no-link --print-out-paths`) and only then point the profile at
  the result in one step (`nix-env --profile <p> --set <out>`), via
  `profile_switch_script`. A profile MUST NOT be deleted or modified before the
  build has succeeded.
- `--set` replaces the profile's contents, so a package removed from the flake
  disappears from PATH. Previous generations stay as a rollback until `gc`.
- The flake ref and profile reach the builder as positional arguments of
  `sh -c`, never spliced into the script.
- The base build runs from `$CONTEXT_DIR` with nixenv's own flake and gets the
  GitHub token (`nix_config`); it passes no `--accept-flake-config` (the base
  flake has no `nixConfig`). Builder runs that fetch nothing (`gc`, gc roots)
  use `nix_config_local`, without the token.
- Store optimisation is incremental (`auto-optimise-store = true` in every
  builder config); only `gc` runs a full `nix store optimise`.

## Why

Installing on top of an existing profile once left removed packages in place,
so `build` deleted the profile first. That made the toolchain disappear for
every running container during a build of several minutes, and for good when the
build failed (rate limit, expired token, hash mismatch): `start` then refused
every project until a build succeeded, although the old store paths were still
there.

## How

The profiles live at `/nix/var/nix/profiles/shared` and `proj-<name>` inside
the `NIX_VOLUME` volume; `run_builder base|project …` runs the nix builder
container. The runtime only reads `bin/`, `etc/` and `sv/` from a profile, so a
plain `buildEnv` output is enough (no `nix profile` manifest).
`ensure_builder_current` brings a bumped `BUILDER_IMAGE`'s nix into an existing
volume (an engine seeds a volume from the image only while it is empty).
