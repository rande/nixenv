---
id: DEP-01
title: "deploy: a throwaway container holding the forwarded agent"
area: deploy
applies-to:
  - "nixenv.sh"
  - "README.md"
enforced-by:
  - tests/unit/38-deploy.sh
  - tests/integration/20-deploy.sh
---

# DEP-01: deploy: a throwaway container holding the forwarded agent

## Rule

- The ssh agent MUST never be forwarded into the dev container. `deploy <p>`
  runs `<prefix>__<p>-deploy` with `--rm`, `container_hardening_args`, the app
  volume read-write at the app mount (the SAME volume), a **tmpfs** home, the
  store, passwd files, the project's authorized_keys + host key, and the
  `deploy-entrypoint.sh`.
- It MUST NOT mount the home volume AS its home, nor the Claude profile. The
  dev home volume is mounted only at `/etc/nixenv/dev-home`, and only its
  `.git-credentials` is read (DEP-04). Tools = the dev container's (project
  profile, then base; `age`/`sops` in base).
- The deploy entrypoint runs no repo/profile hooks or services, copies the
  skeleton into the tmpfs home, exports `GIT_CONFIG_*` overrides for
  `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`, and execs sshd with
  `ListenAddress 127.0.0.1`, agent forwarding on, TCP/stream forwarding off,
  `PermitUserRC no`.
- An EXIT trap removes the container; an existing one is refused
  (`deploy <p> stop` removes a leftover). `stop <p>` and `delete` remove it.

## Why

Everything in the dev container (dependencies, scripts, Claude) runs as the
same uid and could use a forwarded agent. The code is still shared, so scripts
run in deploy are only as trustworthy as the dev container — documented, not
solved; git aliases and filter drivers remain.

## How

`deploy <p> [--agent=<socket>|--no-agent] [-- cmd…]`; `deploy <p>
allow|hosts|log|stop`.
