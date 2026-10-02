---
id: DEP-04
title: "deploy reads git and ssh settings from host-side files only"
area: deploy
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/38-deploy.sh
  - tests/integration/20-deploy.sh
---

# DEP-04: deploy reads git and ssh settings from host-side files only

## Rule

- The home SEED's `.gitconfig.identity`/`.gitconfig.credentials` (read-only)
  and `.git-credentials` (read-write) are bind-mounted straight into the tmpfs
  home — shared, NOT copied.
- Host files `deploy_gitconfig` (included by `.gitconfig`), `deploy_ssh_config`
  (included by `.ssh/config`) and `deploy_known_hosts` (read-write,
  `StrictHostKeyChecking accept-new`) are mounted when present.
- Every one of these MUST be refused if it is a symlink, and none is in
  `EXPORT_META_FILES`.

## Why

The dev container can write none of them. Sharing the credentials file lets a
refreshed token land back in the seed. A token changed in the dev home volume
is not seen — the seed is the source.

## How

`pushInsteadOf` in `deploy_gitconfig` sends an https remote's pushes over ssh
through the agent.
