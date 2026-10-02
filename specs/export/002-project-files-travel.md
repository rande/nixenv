---
id: EXP-02
title: "The whole project dir travels, except what is regenerated"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
  - tests/unit/25-ssh-key-auth.sh
  - tests/integration/14-export-import.sh
---

# EXP-02: The whole project dir travels, except what is regenerated

## Rule

- An export MUST carry every regular file under `~/.nixenv/projects/<p>/`
  (`export_project_files`), at the same relative path under
  `nixenv-export/meta/`: egress and deploy settings, ports, hosts, extra engine
  parameters, `ssh/authorized_keys.extra`, the home seed (dotfiles, git
  identity), and any file added in future.
- It MUST NOT carry what is regenerated per machine (`EXPORT_SKIP_PATHS`):
  `passwd`/`group`/`shadow`, `port`, `etc-hosts`, `flake/`, the generated
  `ssh/` files (`config`, `known_hosts`, `authorized_keys`, the project key and
  host key), and `capture`/`capture-trust`.
- The seed's secrets (`EXPORT_SECRET_PATHS`: `home/.git-credentials`,
  `home/.gitconfig.credentials`, `home/.ssh/`) travel only with `--with-home`.
- Symlinks are never followed into an archive.

## Why

A move or a backup should not lose a project's configuration; an allowlist
silently left new settings (deploy hosts, extra keys, the git identity) behind.
The skipped files embed this machine's uid, port or paths, or would hand the
project's ssh identity to whoever receives the archive. Capture state decides
whether THIS machine's mitmproxy CA is trusted. Credentials follow the same
opt-in as the home volume (EXP-05).

## How

Import treats every file as untrusted (EXP-04). Archives made before this
(flat `meta/<name>`) import unchanged.
