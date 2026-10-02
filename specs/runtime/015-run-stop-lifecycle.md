---
id: RUN-15
title: "run, shell, ssh, stop and logs lifecycle"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/13-stop-all.sh
  - tests/integration/03-run-ssh.sh
---

# RUN-15: run, shell, ssh, stop and logs lifecycle

## Rule

- `run <p>` (no command) starts a DETACHED service container `<prefix>-<p>`.
  `ssh`/`shell` auto-start it; `shell` uses `$ENGINE exec` (no key), `ssh` the
  host ssh client (plain zsh, no zmx).
- `stop <p>` removes the project's container (and its deploy container);
  `stop` with no argument removes every container matching `^<prefix>(-|__)`,
  leaving volumes and projects intact.
- `cmd_run`'s already-running branch MUST warn about settings fixed at creation
  that the running container predates (key-only ssh mount, host-key mount,
  egress address, capture CA).

## Why

Many settings are fixed at container creation; silence would leave users on an
insecure or broken container.

## How

`container_needs_recreate` prints the `stop && run` fix. `gc [--dry-run]` warns
about running containers that may reference paths a rebuild made unreachable.
