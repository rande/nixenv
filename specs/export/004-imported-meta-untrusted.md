---
id: EXP-04
title: "Imported meta files are untrusted"
area: export
security: SEC-01
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/27-import-hostile-meta.sh
---

# EXP-04: Imported meta files are untrusted

## Rule

- `import_meta_files`: regular files only, copied with `cat`.
- `extra-parameters` lands INERT as `extra-parameters.imported` and is printed.
- `ports` keeps only loopback specs (`safe_port_spec`; bare `H:C` becomes
  `127.0.0.1:H:C`).
- `unrestricted` needs an interactive yes (`confirm_tty`); `--yes` does NOT
  grant it; no TTY = stays restricted.
- `allowed_hosts` entries go through `normalize_allowed_host`; `app_mount`
  through `valid_app_mount`; `flake_dir` must be relative without `..`.
- `cmd_run` refuses symlinked `ports`/`hosts.extra`/`extra-parameters`/
  `app_mount` and re-validates the app path.

## Why

These files decide how the container is CREATED on this host. A symlinked
`hosts.extra -> ~/.ssh/id_…` would be bind-mounted; docker binds `0.0.0.0` for
bare `H:C`.

## How

The test builds a hostile meta dir.
