---
id: SSH-04
title: "ssh from another machine: settings stay on the nixenv host"
area: ssh
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/50-ssh-remote.sh
---

# SSH-04: ssh from another machine: settings stay on the nixenv host

## Rule

- `ssh-config --remote[=<alias>]` (run on the nixenv host; default alias
  `hostname -s`) prints ONE generic laptop block: `Host <alias>.*` and, after
  it, `Host <alias>.*.*` (zmx, as SSH-03). It names no project, port or key.
  The alias comes FIRST (`ssh <alias>.<project>[.<session>]`), never
  `<project>.<alias>`.
- Per connection, the laptop's `ProxyCommand` asks the host for the port
  (`ssh-config --port %n`) and tunnels with `ssh -W 127.0.0.1:<port> <alias>`;
  `KnownHostsCommand` fetches the pinned host key
  (`ssh-config --known-hosts %H`), with `UserKnownHostsFile`/
  `GlobalKnownHostsFile /dev/null` and `StrictHostKeyChecking yes`. Both
  lookups use `ssh -n`: the ProxyCommand's stdin is the connection itself.
- `--port` and `--known-hosts` are dispatched in `main` BEFORE
  `materialize_context` (they run on every connection), print ONLY the answer
  on stdout (messages on stderr; `warn` prints to stdout, so `>&2`), and take
  the project from the second label of `<alias>.<project>[.<session>]`,
  validated with `valid_project_name`. `--port` starts a stopped project (like
  `ssh <project>`), with stdin from `/dev/null` and all output on stderr, then
  waits up to 10 s for the port.
- `--remote` also writes `SSH_REMOTE_FILE` (`~/.nixenv/ssh-remote`); while it
  exists, `ensure_project_ssh_key` adds `host_login_keys` to every project's
  `authorized_keys`: the PLAIN key lines of this host's `~/.ssh/authorized_keys`
  (`<type> <base64> [comment]`; a line with options such as `command=`,
  `from=` or `restrict` is left out; a symlinked file is ignored). `--remote`
  and every `--port` lookup rebuild it in place, so a key added to the host
  works at once. `--remote=off` removes the file and rebuilds without them.
  `--port` refuses while it is off.

## Why

On a remote host the project's sshd listens on the host's loopback only. A
laptop block per project would copy the port and key there, and go stale on
every `import` (fresh port, EXP-03) or new project. Fetching the host key from
the host over the authenticated jump keeps SSH-02: a process squatting the port
on the host still fails the check. Whoever can log in to the host as you can
already `nixenv shell` any project, so accepting the same keys grants nothing
new and spares a per-project key step; a key the host restricts (a backup key
limited to `rsync`) would become a full shell, hence plain lines only.
`<project>.<alias>` broke on a laptop that also runs nixenv: its
`Include ~/.nixenv/projects/*/ssh/config` sits at the top of `~/.ssh/config`,
so the local `Host tunnel tunnel.*` block matched `tunnel.devbox` first and its
`HostKeyAlias`, port and key won (ssh keeps the first value). Only a local
project named like the alias can still collide. The plumbing's stdout is parsed by ssh, so a
stray log line would break the connection; and `materialize_context` on every
connection would be slow and write to `~/.nixenv`.

## How

The laptop needs OpenSSH 8.5+ (`KnownHostsCommand`), whose program must be an
absolute path, hence `/bin/sh -c`. The block refers to nixenv by the host's
absolute path of the script (falls back to `nixenv` on the remote PATH when the
path has unusual characters), since a non-interactive ssh may not have
Homebrew's prefix on PATH.
