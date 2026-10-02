---
id: RUN-13
title: "Bare RUNTIME_IMAGE helpers have only Debian tools"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
---

# RUN-13: Bare RUNTIME_IMAGE helpers have only Debian tools

## Rule

- Helpers that run a bare `RUNTIME_IMAGE` container without the store MUST use
  only base-Debian tools (`sed`, `tar`, coreutils). No `git`, `zsh`, `socat`.
- If a helper genuinely needs store tooling, mount `-v "$NIX_VOLUME":/nix:ro`
  and call `$PROFILE/bin/<tool>`.

## Why

`app_git_remote` first used `git`, absent from `debian:stable-slim`; it returned
an empty string and silently skipped the credential prompt on an https import.

## How

`app_git_remote` parses `.git/config` with `sed`.
