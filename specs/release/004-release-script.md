---
id: REL-04
title: "release.sh drives a release end to end, offline-testable"
area: release
applies-to:
  - "release.sh"
  - "docs/index.html"
enforced-by:
  - tests/unit/34-release-script.sh
---

# REL-04: release.sh drives a release end to end, offline-testable

## Rule

- `release.sh <X.Y.Z>` (version mandatory): preflight (`main` only, no tracked
  changes, not behind origin) → bump `NIXENV_VERSION` + `<b id="rev">` in
  `docs/index.html` → syntax + unit suite (EXIT trap reverts the bump on
  failure) → pathspec commit of those two files → annotated tag →
  `git push --atomic origin main <tag>` WITHOUT `--quiet` → poll `release.yml`
  via the GitHub REST API with `curl` → pull → `update-formula.sh` → commit/push
  the formula here and to `./homebrew-nixenv/`.
- NO `gh` dependency, no `shasum`/`sha256sum` in it. Tokens go via
  `curl --config -`, never argv; a token is required only for `--retag`.
- Idempotent: a tag is THIS release when it's HEAD or an ancestor differing only
  by the formula file; anything else needs `--retag`.

## Why

A hidden credential prompt under `--quiet` looked like a hang. Logs need auth,
so on failure it names the failed step and links the run instead.

## How

`./homebrew-nixenv/` is git-ignored (checked with a trailing slash: a dir-only
pattern doesn't match a not-yet-existing path). The test runs the flow offline
with bare repos and a fake `curl`.
