---
id: RUN-01
title: "Project containers run entirely non-root"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/12-init-files.sh
  - tests/integration/03-run-ssh.sh
---

# RUN-01: Project containers run entirely non-root

## Rule

- `run` MUST start the container with `--user $(id -u):$(id -g)` (+
  `engine_userns`) and `--hostname <project>`. The entrypoint does NO root
  operations: `.zshenv`, sshd config, host keys and the runit tree all live
  under the writable `$HOME`.
- The login user `app` comes from generated `passwd`/`group`/`shadow`
  (`write_passwd_files`, in `<project>/`) bind-mounted read-only at
  `/etc/passwd|group|shadow`. Both accounts have password `*`, NOT `!`.

## Why

A compromised container is then just your uid. OpenSSH treats `!` as a locked
account and refuses even pubkey logins.

## How

The shell is `$PROFILE/bin/zsh`. Ownership of the volumes is handled by
RUN-03.
