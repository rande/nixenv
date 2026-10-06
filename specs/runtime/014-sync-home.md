---
id: RUN-14
title: "sync-home refreshes dotfiles into an existing home volume"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/08-sync-home.sh
  - tests/unit/44-sync-home.sh
---

# RUN-14: sync-home refreshes dotfiles into an existing home volume

## Rule

- `sync-home <p>` layers the embedded `home-skel` first, then
  `<repo>/.nixenv/home/` overrides (which win), into the EXISTING home volume.
- The copy (and backup) runs AS THE APP USER: `--user <uid>:<gid>`,
  `engine_userns`, `container_hardening_args`, `cp -R --preserve=mode,timestamps`
  (never `cp -a`, which carries the source's owner). Every file it writes is
  the app user's; there is no chown step. `.ssh` ends 700, its files 600.
- The only root step is a repair BEFORE the copy: `chown -h` of whatever in the
  home volume is not owned by the app user (left by an older root sync), in the
  same userns as the project container. It copies nothing.
- It backs up every overwritten file to `~/.nixenv/home-backups/<ts>` in the
  volume, leaves nvim plugins, shell history and git identity/credentials
  untouched, refreshes the host seed `<project>/home`, mounts the app volume
  read-only, and asks for confirmation first.

## Why

The seed→volume copy is otherwise one-time, so skeleton edits (e.g. the
AstroNvim pin) never propagate. It used to copy as root with `cp -a` and then
chown file by file, silently (`|| true`, output discarded): when the chown
missed, the user was left with root-owned dotfiles in a container that has no
root (RUN-01) to fix them.

## How

The skeleton includes `.ssh/config`, so user `Host` entries there are replaced
(and backed up); per-project overrides keep them.
