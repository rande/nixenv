---
id: RUN-06
title: "Project services: runit dirs refreshed each boot"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
---

# RUN-06: Project services: runit dirs refreshed each boot

## Rule

- Each boot the entrypoint refreshes declared services into `$HOME/.nixenv-sv`
  from TWO sources, repo LAST so it can override: the project profile's
  `$NIXENV_EXTRA_PROFILE/sv/<name>/run`, then `$APP_MOUNT/.nixenv/sv/<name>/run`.
- It then starts a background `runsv` for EVERY dir in `$HOME/.nixenv-sv`
  (including ones installed there directly, e.g. by a setup script).
- A service is removed by deleting its `$HOME/.nixenv-sv/<name>` dir.

## Why

Declaring services as profile FILES avoids nesting heredocs in Nix indented
strings (see TPL-02).

## How

`$HOME/.nixenv-sv` lives in the home volume, so it persists.
