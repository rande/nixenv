---
id: TPL-05
title: "Scratch dirs writable by app; generators assert their result"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
---

# TPL-05: Scratch dirs writable by app; generators assert their result

## Rule

- Scratch dirs MUST be writable by the non-root `app` user:
  `$HOME/.nixenv-run/<scratch>` or a dir inside the app volume — never
  `"$APP.tmp"`.
- Generators that need an EMPTY target build in scratch, copy in, then assert
  the expected file exists and fail loudly.

## Why

With `APP=/app`, `"$APP.tmp"` is `/app.tmp` at the filesystem root: permission
denied, no marker, and an app volume holding just `flake.nix`.

## How

e.g. `composer create-project` into scratch, then copy.
