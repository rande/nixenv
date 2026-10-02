---
id: EXP-03
title: "Machine-specific state is regenerated on import"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
  - tests/integration/14-export-import.sh
---

# EXP-03: Machine-specific state is regenerated on import

## Rule

- On import: `write_passwd_files` for this uid; a fresh port via
  `project_port`; and the restore runs `-u 0` and `chown -R` to your uid.
- `import` onto an EXISTING project needs `--force`; it is as destructive as
  `delete` (each volume is wiped before untarring), so it warns, names the
  volumes, and confirms (`--yes` skips the prompt).
- The refusal message states whether the colliding name came from the archive
  or the argument.

## Why

The archive's files carry the exporting machine's ownership, and
`ensure_volumes` only chowns when the root isn't already yours. The exported
port may be taken here.

## How

"pick another name" reads as nonsense to someone who just passed one.
