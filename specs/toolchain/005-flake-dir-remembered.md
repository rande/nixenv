---
id: TOOL-05
title: "build --dir is remembered per project"
area: toolchain
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/24-flake-dir.sh
---

# TOOL-05: build --dir is remembered per project

## Rule

- `build <p> --dir=<path>` copies a whole folder (relative to the repo, or
  absolute) so a flake with local file references resolves, and MUST be stored
  in `<project>/flake_dir` so a bare `build <p>` reuses it.
- An explicit `--dir=` overrides the stored value; `--dir=` with an EMPTY value
  clears it (the parser tracks `dir_given` separately from `dir`).
- Without `--dir`, only `flake.nix`/`flake.lock` are copied from the repo root.
- `flake_dir` travels in exports.

## Why

Forgetting the flag used to silently build the repo-root flake (or none).

## How

`run` passes the profile path as `NIXENV_EXTRA_PROFILE`; `.zshenv` prepends its
`bin` to PATH when present. `init --build` runs the default build after
scaffolding; `delete` removes the profile.
