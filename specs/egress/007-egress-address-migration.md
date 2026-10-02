---
id: EGR-07
title: "Migrate files that recorded an old egress address"
area: egress
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
---

# EGR-07: Migrate files that recorded an old egress address

## Rule

- The entrypoint records the egress address in `~/.nixenv-egress-proxy`; when it
  changes it rewrites the old address IN PLACE (keeping inode/mode) in
  `.npmrc`, `.yarnrc` and `.ssh/config`.
- `container_needs_recreate` warns about a running container whose
  `NIXENV_EGRESS_PROXY` still points at the old `<prefix>-proxy:3128`.

## Why

Those blocks are written once into the home volume and the `-e` is fixed at
creation; when squid moved to `<prefix>-egress` (and again when the helpers
became `<prefix>__egress`/`<prefix>__proxy`) they kept pointing at a proxy
that no longer existed.

## How

The previous address falls back to the old `.npmrc` block when no record exists.
