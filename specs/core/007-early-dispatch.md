---
id: CORE-07
title: "help, version, install run before materialize_context"
area: core
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/20-version-and-license.sh
  - tests/unit/01-syntax-and-help.sh
---

# CORE-07: help, version, install run before materialize_context

## Rule

- `-h|--help`, `-v|--version|version`, `install` and `uninstall` MUST be
  dispatched in `main` BEFORE `materialize_context`: no engine, no network, no
  writes (no `$CONTEXT_DIR` created).
- The script executes `main` only when run directly (`BASH_SOURCE` guard), so
  tests can `source` it.

## Why

`brew test` runs `--version`; installing must work on a machine with no engine.

## How

`install`/`uninstall` copy the script to `INSTALL_DIR` (default
`/usr/local/bin`) as `INSTALL_NAME` (default `nixenv`). `NIXENV_VERSION` sits at the top of the script and is printed by `--version`
and in the `usage` header.
