---
id: CORE-04
title: "Bash 3.2 for nixenv.sh, POSIX sh for the entrypoints"
area: core
applies-to:
  - "nixenv.sh"
  - "release.sh"
  - "dev/**"
  - "tests/**"
  - "packaging/**"
enforced-by:
  - .github/workflows/ci.yml
  - tests/unit/21-homebrew-formula.sh
---

# CORE-04: Bash 3.2 for nixenv.sh, POSIX sh for the entrypoints

## Rule

- `nixenv.sh` is Bash (`#!/usr/bin/env bash`, `set -euo pipefail`) and MUST run
  on macOS Bash 3.2: no Bash-4 features (associative arrays, `${x,,}`, `mapfile`,
  `;&`), and empty-array expansions guarded as `${a[@]+"${a[@]}"}`.
- Generated scripts that run as `/bin/sh` (entrypoints, egress/start scripts)
  MUST be POSIX sh.
- Under `set -e`, a final `[ test ] && cmd` returns 1 when the test is false —
  use `if … fi` where the statement can be the last in a function or group.

## Why

macOS ships Bash 3.2 and the Homebrew formula deliberately has no `bash`
dependency. The entrypoint runs in `debian:stable-slim` under `/bin/sh`.

## How

CI runs the unit suite on macOS, which is what exercises Bash 3.2. See also
REL-03 (no `depends_on "bash"`).
