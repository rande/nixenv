---
id: DEP-02
title: "deploy connects over ssh carried by engine exec"
area: deploy
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/38-deploy.sh
---

# DEP-02: deploy connects over ssh carried by engine exec

## Rule

- The host connects with `deploy_ssh_argv` (`DEPLOY_SSH` array): `-F /dev/null`,
  the project key + pinned `HostKeyAlias`, `ControlMaster=no`,
  `ProxyCommand $ENGINE exec -i <c> socat - TCP:127.0.0.1:$SSHD_PORT`.
- `--agent=<socket>` becomes ONE argv entry `ForwardAgent="<path>"` (quoted);
  default `NIXENV_DEPLOY_AGENT` or `yes`; `--no-agent` forwards none.
- `cmd_deploy` MUST check `valid_project_name`: the name is spliced into the
  shell-run ProxyCommand.

## Why

No published port or relay, and the agent rides the ssh session — the one way
that works the same on Docker Desktop, Linux and podman (socket mounts don't).
`-F /dev/null` stops a user `Host *` ControlMaster from letting an unrelated
session reuse this one. ssh parses `-o` like a config line, hence the quotes
(needs OpenSSH ≥ 8.2).

## How

The script waits for sshd by polling `socat` through `$ENGINE exec`.
