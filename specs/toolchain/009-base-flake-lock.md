---
id: TOOL-09
title: "The base flake.lock ships inside nixenv.sh"
area: toolchain
applies-to:
  - "nixenv.sh"
  - "dev/embed-flake-lock.sh"
  - "release.sh"
enforced-by:
  - tests/unit/48-base-flake-lock.sh
---

# TOOL-09: The base flake.lock ships inside nixenv.sh

## Rule

- `embedded_flake_lock` (heredoc `NIXENV_FLAKE_LOCK`) holds the base flake's
  lock as of the release. `materialize_context` writes it to
  `$CONTEXT_DIR/flake.lock` ONLY when that file is missing; an existing lock
  (rolled forward by `update`) is never replaced. Empty = nothing shipped.
- When present it MUST pin exactly the base flake's inputs (`nixpkgs`,
  `nixpkgs-unstable`), each with a `narHash`.
- `dev/embed-flake-lock.sh [lock]` (default `~/.nixenv/context/flake.lock`,
  produced by `./nixenv.sh update`) checks the lock and replaces the heredoc
  body; the result must still parse. `release.sh` warns, without failing,
  while no lock is embedded.

## Why

Without a shipped lock the first `build` on each machine resolved whatever
`nixos-26.05` and `nixos-unstable` pointed at that day: two users of one
version got different toolchains (a different Claude CLI among them), a bad
unstable revision broke fresh installs of a release that worked when tagged,
and the resolution went through GitHub's rate-limited API.

## How

The refresh needs an engine and the network, so it is a manual step before a
release (RELEASING.md, "Refreshing the base flake.lock").
