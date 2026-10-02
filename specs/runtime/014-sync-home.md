---
id: RUN-14
title: "sync-home refreshes dotfiles into an existing home volume"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/08-sync-home.sh
---

# RUN-14: sync-home refreshes dotfiles into an existing home volume

## Rule

- `sync-home <p>` layers, via a root helper, the embedded `home-skel` first,
  then `<repo>/.nixenv/home/` overrides (which win), into the EXISTING home
  volume.
- It backs up every overwritten file to `~/.nixenv/home-backups/<ts>` in the
  volume, leaves nvim plugins, shell history and git identity/credentials
  untouched, refreshes the host seed `<project>/home`, mounts the app volume
  read-only, and asks for confirmation first.

## Why

The seed→volume copy is otherwise one-time, so skeleton edits (e.g. the
AstroNvim pin) never propagate.

## How

The skeleton includes `.ssh/config`, so user `Host` entries there are replaced
(and backed up); per-project overrides keep them.
