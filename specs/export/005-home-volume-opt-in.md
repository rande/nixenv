---
id: EXP-05
title: "The home volume is opt-in"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
---

# EXP-05: The home volume is opt-in

## Rule

- A default archive is `app + databases` only. The home volume is included only
  with `--with-home`, and only then does the SECRET warning fire.
- With no home volume, import calls `seed_project_home` +
  `configure_git_identity` BEFORE `ensure_volumes`.
- `seed_project_home` is shared with `cmd_init` (one definition).

## Why

The home volume holds `~/.ssh` and `~/.git-credentials`: including it by default
would make every backup a credential leak, and an always-on warning becomes
noise. `ensure_volumes` copies `<project>/home` into the volume; after it, the
volume would be seeded from an empty directory.

## How

The unit test asserts both the sharing and the ordering.
