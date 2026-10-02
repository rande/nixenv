---
id: EXP-02
title: "Only allowlisted host-side files travel"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
  - tests/unit/38-deploy.sh
---

# EXP-02: Only allowlisted host-side files travel

## Rule

- `EXPORT_META_FILES` is an ALLOWLIST: `ports app_mount hosts.extra
  allowed_hosts unrestricted extra-parameters flake_dir accept-from ssh_hosts`.
  A new per-project file stays behind until someone adds it deliberately.
- Machine-specific state (`passwd`/`group`/`shadow`, `port`, `etc-hosts`,
  `flake`, `ssh`, `home`), `capture`, `capture-trust` and every `deploy_*` file
  MUST NOT be exported.

## Why

An exclude list leaks whatever is added next.

## How

The unit test fails if machine-specific state appears in the list.
