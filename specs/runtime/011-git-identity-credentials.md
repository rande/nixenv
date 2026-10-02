---
id: RUN-11
title: "Per-project git identity and https credentials"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/12-init-files.sh
  - tests/unit/36-init-branch.sh
---

# RUN-11: Per-project git identity and https credentials

## Rule

- Git identity lives in `<project>/home/.gitconfig.identity`, included by the
  project `.gitconfig`; `init` prompts (or uses `GIT_USER_NAME`/`GIT_USER_EMAIL`).
- For an http(s) clone URL, `init` prompts (or uses `GIT_HTTP_USER`/
  `GIT_HTTP_TOKEN`) and stores credentials with git's `store` helper:
  `home/.git-credentials` (mode 600) + `home/.gitconfig.credentials`.
  `configure_git_credentials` runs BEFORE `clone_repo`.
- `init <url> [--branch=B]` clones with `git clone [--branch B] -- <url>` as
  your uid; `valid_git_branch` rejects a leading `-` and odd characters before
  anything is created; `--branch` without a URL is refused.

## Why

Re-running `init` must never duplicate the `[user]` block. `--` stops a URL
starting with `-` (e.g. `-u…` = `--upload-pack`) being read as an option.

## How

`seed_project_home` is shared by `init` and `import`. `clone_repo` runs
unrestricted (default bridge), once.
