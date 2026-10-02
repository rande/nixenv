---
id: TEST-02
title: "Test layout and harness"
area: testing
applies-to:
  - "tests/**"
---

# TEST-02: Test layout and harness

## Rule

- One bash file per test in `tests/unit/` and `tests/integration/`; exit 0 =
  pass, 77 = skip, else fail. Runner: `tests/run.sh [unit|integration|all|<files>]`.
- Unit tests SOURCE `nixenv.sh` and isolate with `NIXENV_PROJECTS_DIR`,
  `PROXY_DIR`, `CLAUDE_DIR`, `CLAUDE_JSON`, `CONTEXT_DIR`, `CONTAINER_PREFIX`.
- Integration tests need a real engine and a DEDICATED environment (`nxt`
  prefix and state dirs, sweeping `nxt-*`/`nxt__*` containers and `nxt_*`
  volumes/networks), reusing the shared store volume.
- `fail` inside a pipeline's `while` runs in a subshell — don't assert there.

## Why

Tests must never touch a user's real projects or containers.

## How

`tests/run-in-docker.sh` runs everything in disposable docker-in-docker (cache
volume `nixenv-dind-cache`). `tests/lib.sh` sets `NIXENV_SH` itself.
