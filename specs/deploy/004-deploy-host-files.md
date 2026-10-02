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

- Git identity: the home SEED's `.gitconfig.identity` (host-side, read-only),
  bind-mounted into the tmpfs home. Never a gitconfig from the dev home volume.
- Git https credentials: the deploy entrypoint GENERATES `.gitconfig.credentials`
  with two `store` helpers, in order: `--file=/etc/nixenv/dev-home/.git-credentials`
  (the dev home volume, mounted at that side path) then the seed's
  `.git-credentials` (bind-mounted read-write at `~/.git-credentials`).
  Nothing else is read from the dev home volume.
- Host files `deploy_gitconfig` (included by `.gitconfig`), `deploy_ssh_config`
  (included by `.ssh/config`) and `deploy_known_hosts` (read-write,
  `StrictHostKeyChecking accept-new`) are mounted when present.
- Every host file here MUST be refused if it is a symlink. They travel in
  exports; on import the configs are gated and the seed's identity and
  credentials sanitised (EXP-04).

## Why

A deploy must push with the credentials that work for the developer: the seed's
copy is written once by `init` and went stale when the token was changed in the
dev container, so pushes authenticated with an old read-only token ("Permission
denied to <user>", 403). The credential file is DATA parsed by git's own store
helper, so reading it from the dev-writable volume adds no execution path; a
gitconfig from there could add a credential helper that would run next to the
agent, so the identity and the helper config never come from it. git asks the
helpers in order and uses the first answer, so the seed is only a fallback.

## How

`pushInsteadOf` in `deploy_gitconfig` sends an https remote's pushes over ssh
through the agent.
