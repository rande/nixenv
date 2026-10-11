---
id: TOOL-06
title: "PATH order: ~/.local/bin, project profile, base"
area: toolchain
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
  - tests/unit/38-deploy.sh
---

# TOOL-06: PATH order: ~/.local/bin, project profile, base

## Rule

- PATH MUST be `$HOME/.local/bin` → project profile → base profile →
  `$HOME/.cargo/bin` → system dirs, identically
  in every place that sets it: the entrypoint's `.zshenv` (ssh/zmx logins), the
  entrypoint's own `export PATH` (hooks + runit services), the ephemeral
  `run <project> cmd` branch, `home-skel/.zshrc` (re-asserts it because
  oh-my-zsh reorders PATH), and the deploy entrypoint.
- The entrypoint MUST `mkdir -p ~/.local/bin` so it exists before anything
  installs there.

## Why

Otherwise a tool resolves differently depending on how you got a shell.
`~/.local/bin` leads so user installs (pip --user, pipx, dropped binaries) win;
it lives in the home volume and persists.

## How

The test parses every `export PATH=` line (entrypoint, `.zshrc`, deploy
entrypoint), checks `.local/bin` comes first, and that all of them normalise
to the SAME list (`.zshrc` keeps the inherited `$PATH` tail). `~/.cargo/bin`
was once only in the login shells, so a `cargo install`ed tool ran in ssh but
not in a hook or a service.
