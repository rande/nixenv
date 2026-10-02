---
id: SSH-02
title: "The container host key is pinned"
area: ssh
security: SEC-10
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/31-host-key-pinning.sh
---

# SSH-02: The container host key is pinned

## Rule

- `ensure_project_ssh_key` also generates `<project>/ssh/host_ed25519_key` on
  the host and writes `<project>/ssh/known_hosts` as `nixenv-<name> <key>`
  (`ssh_host_alias`).
- `cmd_run` mounts it read-only at `/etc/nixenv/ssh_host_ed25519_key`; the
  entrypoint COPIES it into `$SSHRUN`, chmods 600, and offers only that key.
- Client side uses `StrictHostKeyChecking yes` + `HostKeyAlias` + the
  per-project `UserKnownHostsFile` (ssh config and `cmd_ssh`).

## Why

A process squatting the project's port after the container stops must not be
able to impersonate it. sshd rejects a group/world-readable key and a bind
mount keeps the host's mode/owner, hence the copy.

## How

Without the mount (older containers) the entrypoint falls back to keys
generated in `~/.ssh`. Older ssh configs get just the two generated lines
swapped (awk), hand edits kept.
