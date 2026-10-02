---
id: CORE-03
title: "Docker and podman through $ENGINE"
area: core
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/06-img-podman.sh
---

# CORE-03: Docker and podman through $ENGINE

## Rule

- Every container call MUST go through `"$ENGINE"`; never hardcode `docker`.
- Image references MUST be wrapped in `img` (prefixes `docker.io/` for podman
  short names).
- `--userns=keep-id` is added only via `engine_userns`, and only for ROOTLESS
  podman (rootful podman rejects it).

## Why

nixenv supports docker and podman (rootless and rootful). A hardcoded `docker`
breaks podman-only hosts.

## How

`resolve_engine` picks the binary: env `CONTAINER_ENGINE` → remembered
`~/.nixenv/engine` → auto-detect (prompting if both are installed). It returns
non-zero (not `die`) when none is found, so host-file work like `delete` still
runs. `require_engine` caches `ENGINE_ROOTLESS` from `podman_rootless_probe`.
