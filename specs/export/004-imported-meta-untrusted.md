---
id: EXP-04
title: "Imported meta files are untrusted"
area: export
security: SEC-01
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/27-import-hostile-meta.sh
  - tests/integration/14-export-import.sh
---

# EXP-04: Imported meta files are untrusted

## Rule

- `import_meta_files`: regular files with plain relative paths only (no `..`,
  no odd characters), copied with `cat`; files in `EXPORT_SKIP_PATHS` are
  ignored even when present.
- Files that change how the container is created, who can log in, or what runs
  next to the agent — `extra-parameters`, `deploy_ssh_config`,
  `deploy_gitconfig`, `deploy_known_hosts`, `ssh/authorized_keys.extra` — are
  SHOWN and applied only after an interactive yes (`import_gated`); otherwise
  they land as `<file>.imported`. `--yes` does NOT grant it.
- `ports` keeps only loopback specs (`safe_port_spec`; bare `H:C` becomes
  `127.0.0.1:H:C`).
- `unrestricted` needs an interactive yes (`confirm_tty`); no TTY = stays
  restricted.
- `allowed_hosts`, `deploy_hosts`, `ssh_hosts` go through
  `normalize_allowed_host`; `app_mount` through `valid_app_mount`; `flake_dir`
  must be relative without `..`.
- `home/.gitconfig.identity` is REBUILT from name + email (refused if they hold
  config syntax); `home/.git-credentials` keeps credential-store lines only
  (mode 600); `home/.gitconfig.credentials` is rewritten by nixenv.
- `cmd_run` refuses symlinked `ports`/`hosts.extra`/`extra-parameters`/
  `app_mount` and re-validates the app path.

## Why

These files decide how the container is CREATED on this host, and an archive
may be someone else's. A symlinked `hosts.extra -> ~/.ssh/id_…` would be
bind-mounted; docker binds `0.0.0.0` for bare `H:C`; a git identity file is
included by every git config — deploy's too — so a crafted one could add a
credential helper that runs next to your agent. Your own archive still restores
everything: you answer yes.

## How

The test builds a hostile meta dir.
