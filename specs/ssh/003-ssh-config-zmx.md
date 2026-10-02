---
id: SSH-03
title: "Host ssh config with zmx sessions"
area: ssh
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/25-ssh-key-auth.sh
  - tests/unit/31-host-key-pinning.sh
---

# SSH-03: Host ssh config with zmx sessions

## Rule

- `write_host_ssh_config` writes `<project>/ssh/config` once (never clobbers
  edits): `Host <name> <name>.*` → 127.0.0.1:port, `RemoteCommand zmx attach %n`,
  `ControlMaster auto` with `ControlPersist`.
- MUST use `%n` (host as typed), NOT `%k` (the HostKeyAlias, which made every
  `ssh <p>.<x>` share one session); old configs are migrated.
- `ssh-config --install` adds `Include ~/.nixenv/projects/*/ssh/config` to
  `~/.ssh/config`.

## Why

Re-attachable named sessions per `ssh <p>.<x>`. zmx is installed per TOOL-03;
no tmux, no zellij.

## How

The starship prompt shows `$NIXENV_PROJECT`, `$ZMX_SESSION` and the hostname
(= project name).
