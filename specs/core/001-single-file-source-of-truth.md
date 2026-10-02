---
id: CORE-01
title: "nixenv.sh is self-contained"
area: core
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/02-materialize-context.sh
---

# CORE-01: nixenv.sh is self-contained

## Rule

- `nixenv.sh` MUST stay a single self-contained script. Every supporting file is
  embedded in `materialize_context()` as a heredoc: `flake.nix` (`NIXENV_FLAKE`),
  `Dockerfile` (reference only, `NIXENV_DOCKERFILE`), `entrypoint.sh`
  (`NIXENV_ENTRYPOINT`), `deploy-entrypoint.sh` (`NIXENV_DEPLOY_ENTRYPOINT`) and
  `home-skel/*` (`.zshrc`, `.gitconfig`, `.config/starship.toml`,
  `.config/nvim/init.lua`, `.vimrc`, `.gitignore`, `.ssh/config`).
- MUST NOT recreate standalone `flake.nix` / `runtime/` files at the repo root.
  To change an embedded file, edit its heredoc in `nixenv.sh`.
- `dev/flake.nix` and `examples/hello/flake.nix` are PROJECT flakes, not copies
  of the base; they stay out of the root.

## Why

One file is what users install (Homebrew, `install`, the release asset). A
second copy of any embedded file would drift from the one that actually runs.

## How

On every command, `materialize_context()` writes the files into `$CONTEXT_DIR`
(default `~/.nixenv/context`) and the build runs from there. `flake.lock` is
never written by the script, so it persists in `$CONTEXT_DIR` across runs.
