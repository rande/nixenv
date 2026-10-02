---
id: SSH-01
title: "Container sshd accepts only the host-generated project key"
area: ssh
security: SEC-02
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/25-ssh-key-auth.sh
  - tests/integration/15-ssh-keyauth.sh
---

# SSH-01: Container sshd accepts only the host-generated project key

## Rule

- `ensure_project_ssh_key` generates `<project>/ssh/id_ed25519` on the HOST
  (host `ssh-keygen`, else the store's) BEFORE the ssh config is written.
- `<project>/ssh/authorized_keys` = project key + the user's
  `authorized_keys.extra`, rewritten IN PLACE (keeps the bind-mounted inode).
  It is mounted read-only at `/etc/nixenv/authorized_keys`, sshd's ONLY
  `AuthorizedKeysFile` (`AuthenticationMethods publickey`, passwords off).
- The entrypoint MUST NOT build authorized keys from the home volume.
- The project key, host key and generated `ssh/` files are never exported
  (re-created on import); only `ssh/authorized_keys.extra` travels, gated.

## Why

sshd listens on every interface, reachable from other projects on `nixenv_net`;
an open login meant any project could get a shell in any other. A writable keys
file inside the container let it authorise itself.

## How

`write_host_ssh_config` adds `IdentityFile`/`IdentitiesOnly` (inserted after
`User` in older configs, hand edits kept); `cmd_ssh` passes `-i`. Old
containers are detected by the missing mount and warned about.
