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

- `build <p> --dir=<path>` copies a whole folder of the REPO (the app volume)
  so a flake with local file references resolves, and MUST be stored
  in `<project>/flake_dir` so a bare `build <p>` reuses it.
- An explicit `--dir=` overrides the stored value; `--dir=` with an EMPTY value
  clears it (the parser tracks `dir_given` separately from `dir`).
- Without `--dir`, only `flake.nix`/`flake.lock` are copied from the repo root.
- An absolute `--dir` (it would be read INSIDE the volume, not on the host) or
  one containing `..` is refused; `./` and a trailing `/` are normalised;
  `--dir=.` warns that the whole repo is copied into the store on every build.
- `flake_dir` travels in exports.

## Why

Forgetting the flag used to silently build the repo-root flake (or none).

## How

`run` passes the profile path as `NIXENV_EXTRA_PROFILE`; `.zshenv` prepends its
`bin` to PATH when present. `init --build` runs the default build after
scaffolding; `delete` removes the profile.
