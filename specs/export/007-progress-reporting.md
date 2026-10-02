---
id: EXP-07
title: "Progress meter only for export/import tars"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
---

# EXP-07: Progress meter only for export/import tars

## Rule

- Both tars run with `-v` and pipe the listing through `progress_count` — the
  ONLY long step nixenv reports on itself.
- Counting is done in `awk`, not a bash `read` loop. Without a TTY it prints
  periodic whole lines instead of `\r`. `NIXENV_PROGRESS=0` silences it but
  still drains stdin.
- tar's stderr stays visible.

## Why

`build`, clone and `gc` already report through nix/git, and a second meter
would fight theirs. 200k files = 200k lines; bash would be the bottleneck. A
full pipe would block tar. "file changed as we read it" on a `--force` export
is exactly what the user should see.

## How

The listing goes to the container's stdout (the archive is a mounted file).
