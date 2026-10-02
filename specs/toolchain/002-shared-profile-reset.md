---
id: TOOL-02
title: "build resets the shared profile before installing"
area: toolchain
applies-to:
  - "nixenv.sh"
---

# TOOL-02: build resets the shared profile before installing

## Rule

- `build` MUST remove the shared profile and its generation links before
  `nix profile install`, so flake changes take effect.
- The base build runs from `$CONTEXT_DIR` with nixenv's own flake (trusted:
  `--accept-flake-config` and the GitHub token are allowed there only).

## Why

Installing on top of an existing profile left removed packages in place.

## How

The profile lives at `/nix/var/nix/profiles/shared` inside the `NIX_VOLUME`
volume; `run_builder base …` runs the nix builder container.
