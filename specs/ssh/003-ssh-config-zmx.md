---
id: SSH-03
title: "Host ssh config with zmx sessions"
area: ssh
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/25-ssh-key-auth.sh
  - tests/unit/31-host-key-pinning.sh
  - tests/unit/10-entrypoint-content.sh
---

# SSH-03: Host ssh config with zmx sessions

## Rule

- `write_host_ssh_config` writes `<project>/ssh/config` once (never clobbers
  edits) with TWO blocks:
  - `Host <name> <name>.*`: the shared settings, → 127.0.0.1:port with the
    project key, pinned host key and `ControlMaster auto` + `ControlPersist`,
    and NO `RemoteCommand`, so `ssh <name>` is a plain shell and
    `ssh <name> <cmd>` runs a command;
  - `Host <name>.*`, after it: only `RequestTTY yes` and
    `RemoteCommand zmx attach %n`.
- Host patterns MUST be exact names, never a prefix wildcard `<name>*`: that
  would also match another project (`<name>-api`) and, ssh keeping the first
  value, connect it to this project's container.
- MUST use `%n` (host as typed), NOT `%k` (the HostKeyAlias, which made every
  `ssh <p>.<x>` share one session); old configs are migrated.
- A config from the single `Host <name> <name>.*` era is NOT migrated: it keeps
  zmx on the bare name until the user deletes it (the next `start` rewrites it).
- The entrypoint's `.zshenv` MUST export `ZMX_DIR=/tmp/zmx-<uid>` (the uid
  baked in at write time), so every shell (ssh login, the `zmx attach`
  RemoteCommand, `shell`) looks for sessions in the same directory.
- `ssh-config --install` adds `Include ~/.nixenv/projects/*/ssh/config` to
  `~/.ssh/config`.

## Why

Re-attachable named sessions per `ssh <p>.<x>`; the bare name stays a plain
shell so `ssh <p> <cmd>`, scp/rsync and tools that run their own remote
command (VS Code Remote-SSH) work (a `RemoteCommand` conflicts with a
command-line one). zmx is installed per TOOL-03;
no tmux, no zellij.

zmx takes its socket dir from `ZMX_DIR`, else `$XDG_RUNTIME_DIR/zmx`, else
`/tmp/zmx-<uid>`. A project setup script exported `XDG_RUNTIME_DIR` (for
rootless podman) into interactive shells only: a session started over ssh
lived in `/tmp/zmx-1000` while `zmx list` in a shell searched
`~/.devenv/run/user/zmx` and reported no sessions. `/tmp/zmx-<uid>` is the
old default, so sessions started before the pin stay visible.

## How

The starship prompt shows `$NIXENV_PROJECT`, `$ZMX_SESSION` and the hostname
(= project name).
