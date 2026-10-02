---
id: TPL-04
title: "Project files are created by the hook, marker-guarded"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
enforced-by:
  - tests/lib-template.sh
---

# TPL-04: Project files are created by the hook, marker-guarded

## Rule

- Anything that creates project files (`wp core download`,
  `composer create-project`, `npm install`, scaffolding) MUST run in the startup
  hook, guarded by `$APP_MOUNT/.nixenv/.<template>-installed`.

## Why

A Nix build is sandboxed to `$out` and cannot write the app volume. The marker
keeps restarts instant.

## How

Windmill is the exception: its scripts live in PostgreSQL (TPL-13).
