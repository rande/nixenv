---
id: TOOL-01
title: "The base flake ships no language runtimes"
area: toolchain
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/02-materialize-context.sh
---

# TOOL-01: The base flake ships no language runtimes

## Rule

- The embedded base flake is a shell/editor/CLI toolbox. It MUST NOT ship
  language runtimes (Node, PHP, Python, Go, Rust, Ruby), package managers
  (composer, uv), sqlite, or language servers that need a runtime (pyright,
  intelephense, gopls, …).
- Only `lua-language-server` and `bash-language-server` stay (they need nothing
  on PATH); the nvim packs in the home skeleton mirror this (bash/lua only).
- Runtimes belong in a per-project flake, runtime and its LSP together.
- Packages nixpkgs wraps with their own interpreter are fine: `claude-code`, the
  two language servers, `mitmproxy` (only `mitm*` on PATH). Standalone binaries
  such as `age` and `sops` are fine.

## Why

Every project shares the base; each project pins its own runtimes and nothing
pays for toolchains it doesn't use.

## How

The test compares only the package list (comments legitimately name runtimes as
examples) and checks the nvim packs match the shipped servers.
