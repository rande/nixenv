---
id: REL-01
title: "NIXENV_VERSION and the GPL licence"
area: release
applies-to:
  - "nixenv.sh"
  - "LICENSE"
enforced-by:
  - tests/unit/20-version-and-license.sh
---

# REL-01: NIXENV_VERSION and the GPL licence

## Rule

- `NIXENV_VERSION` at the top of the script is printed by `--version` and the
  usage header; bump it in the same commit as the release tag.
- Licence is GPL-3.0-or-later: verbatim FSF text in `LICENSE` (~35 kB; a
  truncated one is rejected); the script header carries the copyright and
  no-warranty notice.

## Why

The Homebrew formula's `test` asserts the version matches its tag.

## How

See CORE-07 for early dispatch.
