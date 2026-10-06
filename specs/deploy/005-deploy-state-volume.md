---
id: DEP-05
title: "deploy keeps state in its own volume, created on first use"
area: deploy
applies-to:
  - "nixenv.sh"
  - "README.md"
enforced-by:
  - tests/unit/38-deploy.sh
  - tests/unit/23-export-import.sh
  - tests/integration/20-deploy.sh
---

# DEP-05: deploy keeps state in its own volume, created on first use

## Rule

- `deploy_volume` = `<prefix>_<p>_deploy`, mounted read-write at `/deploy` in
  the deploy container ONLY (`NIXENV_DEPLOY_STATE=/deploy`, also exported in
  its `.zshenv`). It MUST NOT be mounted in the dev container or any helper
  that runs project code.
- It is created lazily by `deploy_open` (`ensure_deploy_volume`), never by
  `init`/`run`/`ensure_volumes`, and reused by every later session. Like
  RUN-03, a root helper drops `.keep` into it when empty and chowns it only when
  the root isn't already your uid.
- `/deploy` is a reserved path for `valid_app_mount`.
- `delete` removes it. `export` includes it as `volumes/deploy.tar.gz` when it
  exists (manifest `deploy=0|1`), refuses while a deploy session is open
  (unless `--force`), and warns that the archive may hold deployment secrets.
  `import` creates and restores it (`-u 0`, `chown -R`) only when the archive
  has one; `--force` says whether it is replaced.

## Why

The deploy home is a tmpfs, so terraform/ansible state and release bookkeeping
were lost after every session. Keeping it out of the dev container keeps
production state (often holding secrets) away from untrusted dev code, which
also cannot plant files there for a later session holding the agent. Created
on first use so projects that never deploy get no extra volume.

## How

An imported state volume is restored only into `/deploy` of the deploy
container; treat it like the app volume — data you run with your agent.
