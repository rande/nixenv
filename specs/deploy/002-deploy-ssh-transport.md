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

- The host connects to `deploy_ssh_host` = `nixenv-deploy-<p>` (fixed
  `nixenv-`, independent of `CONTAINER_PREFIX`) so the user's `~/.ssh/config`
  can match it, e.g. `Host nixenv-deploy-*` with `IdentityAgent`.
- `deploy_ssh_argv` (`DEPLOY_SSH` array) MUST pin with `-o` everything the
  session depends on: the project key + `IdentitiesOnly`, `StrictHostKeyChecking
  yes` + `HostKeyAlias` + the project's known_hosts, `ControlMaster=no`,
  `ControlPath=none`, `RemoteCommand=none`, `PermitLocalCommand=no`, and
  `ProxyCommand $ENGINE exec -i <c> socat - TCP:127.0.0.1:$SSHD_PORT`.
- Agent: default `auto` (`NIXENV_DEPLOY_AGENT` overrides) leaves `ForwardAgent`
  to the config when `ssh -G` shows it set, else passes `ForwardAgent=yes`;
  `--agent=<socket>` passes ONE argv entry `ForwardAgent="<path>"`;
  `--no-agent` passes `no`.
- `cmd_deploy` MUST check `valid_project_name`: the name is spliced into the
  shell-run ProxyCommand.

## Why

No published port or relay, and the agent rides the ssh session — the one way
that works the same on Docker Desktop, Linux and podman (socket mounts don't).
ssh keeps the FIRST value it obtains and `-o` precedes the config file, so the
user's config can choose the agent but not the transport, key, host-key check,
or reuse a `Host *` ControlMaster (which would let a later, unrelated session
ride this one). With `IdentityAgent` set, ssh exports it as `SSH_AUTH_SOCK` for
the session, so `ForwardAgent yes` forwards THAT agent (verified with OpenSSH
10.5). `-o` is parsed like a config line, hence the quoted path (OpenSSH ≥ 8.2).

## How

The script waits for sshd by polling `socat` through `$ENGINE exec`.
