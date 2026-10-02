---
id: TOOL-08
title: "Claude CLI from nixpkgs-unstable on the shared profile"
area: toolchain
applies-to:
  - "nixenv.sh"
---

# TOOL-08: Claude CLI from nixpkgs-unstable on the shared profile

## Rule

- `claude-code` comes from `nixpkgs-unstable` (fast-moving); the rest of the
  toolchain from the stable channel. `update` rolls both locks forward.

## Why

The CLI moves faster than a stable channel.

## How

Per-project isolation of its state is RUN-12.
