---
id: TOOL-04
title: "Project flakes are untrusted"
area: toolchain
security: SEC-04
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/29-project-build-trust.sh
---

# TOOL-04: Project flakes are untrusted

## Rule

- Project builds MUST NOT use `--accept-flake-config` and MUST use
  `nix_config_project` (never `nix_config`), which sets
  `accept-flake-config = false`, `sandbox = true`, `sandbox-fallback = true`.
- The GitHub token MUST NOT reach a project build.

## Why

A flake's `nixConfig` could add a substituter AND its signing key to the SHARED
store, poisoning every project.

## How

`cmd_build_project` copies the flake into `<project>/flake/` and installs
`path:/flake#$PROJECT_ATTR` into `/nix/var/nix/profiles/proj-<name>`
(`project_profile`). The unprivileged builder usually can't sandbox, so it
often falls back; a one-time warning per project is recorded in
`.flake-trust-noted`.
