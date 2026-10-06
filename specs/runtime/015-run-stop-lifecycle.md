---
id: RUN-15
title: "run, shell, ssh, stop and logs lifecycle"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/13-stop-all.sh
  - tests/integration/03-run-ssh.sh
  - tests/unit/43-start-output.sh
---

# RUN-15: run, shell, ssh, stop and logs lifecycle

## Rule

- `start <p>` (alias `run`; no command) starts a DETACHED service container
  `<prefix>-<p>`. User-facing text (help, hints, docs) names `start`.
- `start` prints a SHORT summary by default (`run_summary`: status, ssh/shell,
  web URL, egress state as a host count, capture, a pointer to `-v`). It sets
  `NIXENV_QUIET=1` for everything it calls, which silences `log`/`ok` (and the
  `proxy up` info block) but NEVER `warn`/`die`. `start <p> -v` (`--verbose`)
  prints every step and the full details.
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
insecure or broken container. The full output (every step, the whole allowlist, the proxy's
info block) buried the two lines a user needs on each start, so it is opt-in;
warnings stay visible because they are the ones that need action.

## How

`container_needs_recreate` prints the `stop && start` fix. `gc [--dry-run]` warns
about running containers that may reference paths a rebuild made unreachable.

`cmd_ssh` and `cmd_shell` do not `exec` the client: when it returns (even
after a dropped session) they call `terminal_reset`, which switches off mouse
reporting, bracketed paste and the alternate screen and runs `stty sane` (TTY
only), then return the client's exit code. A session killed mid-app (zmx, nvim,
Claude Code) otherwise left the host shell printing `64;65;57M` on every
scroll. A plain `ssh <project>` through the ssh config can't be wrapped: there,
`reset` restores the terminal.
