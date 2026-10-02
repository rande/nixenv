---
id: RUN-03
title: "Named volumes, owned by your uid"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/02-volumes.sh
---

# RUN-03: Named volumes, owned by your uid

## Rule

- Code, home and databases are named volumes `<prefix>_<p>_app` → app mount,
  `<prefix>_<p>_home` → `/home/app`, `<prefix>_<p>_databases` → `/databases`.
- `ensure_volumes` creates missing volumes, then a one-time root helper (`-u 0`)
  seeds an empty home from `<project>/home`, drops `.keep` into empty
  `/app`/`/databases`, and chowns to your uid ONLY when the root isn't already
  yours.
- `clone_repo` removes `/app/.keep` before cloning and ignores it in the
  empty-check.

## Why

Named volumes start root-owned; the chown is what lets a non-root container use
them. Docker Desktop resets an EMPTY named volume's ownership to root on the
next mount — a non-empty one keeps it, hence `.keep`. Correctly-owned data is
never re-chowned.

## How

Host-side per-project state stays small: `<project>/home` (the seed), `port`
(stable random SSH port via `project_port`) and the meta files.
