---
id: CORE-08
title: "Never commit or casually destroy ~/.nixenv/projects"
area: core
applies-to:
  - "nixenv.sh"
---

# CORE-08: Never commit or casually destroy ~/.nixenv/projects

## Rule

- `$HOME/.nixenv/projects/` holds user data (SSH keys, home seeds, credentials).
  It lives outside the repo: never commit it, and avoid destructive operations
  on it.
- Projects always live in `$HOME/.nixenv/projects` — not a user setting.
  `NIXENV_PROJECTS_DIR` exists only for test isolation.
- `delete` prints every command it will run (containers, volumes — the deploy
  state volume included — profile, host dir, captures, Claude profile) and
  asks before running them.

## Why

Deleting it loses keys, tokens and git identity with no way back.

## How

`cmd_delete` keeps Claude transcripts; it removes the project's profile in the
store, its internal and deploy networks (disconnecting the proxies first) and
its recorded captures.
