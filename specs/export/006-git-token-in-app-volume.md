---
id: EXP-06
title: "Tokens embedded in the app volume are refused"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
---

# EXP-06: Tokens embedded in the app volume are refused

## Rule

- `export` MUST refuse (unless `--force`) when `app_git_embedded_creds` finds a
  token in a remote URL (`https://user:token@host/…` in `.git/config`), masking
  the token and naming the `git remote set-url` fix.
- `import` runs `app_scrub_git_creds` as defence in depth. Only http(s) URLs are
  scrubbed (`ssh://git@host` is a username, not a secret).
- On a no-home import with an http(s) origin, `configure_git_credentials`
  prompts for a token and `sync_home_files` copies it into the home VOLUME.

## Why

The app volume is in every archive, so excluding the home volume alone doesn't
make an archive safe. Scrubbing the user's own remote silently would be worse
than refusing. The home volume was seeded earlier, so writing only to
`<project>/home` would never reach the container.

## How

`app_git_*` helpers parse with `sed`, never `git` (RUN-13).
