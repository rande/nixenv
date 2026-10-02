---
id: REL-03
title: "Homebrew formula: no dependencies, may lag the version"
area: release
applies-to:
  - "packaging/**"
  - "nixenv.sh"
enforced-by:
  - tests/unit/21-homebrew-formula.sh
---

# REL-03: Homebrew formula: no dependencies, may lag the version

## Rule

- The formula (personal tap `rande/homebrew-nixenv`) has NO dependencies; never
  add `depends_on "bash"` without changing the shebang.
- Its `url` tag MUST NOT be ahead of `NIXENV_VERSION`; it may lag.
- `update-formula.sh <version>` rewrites `url`+`sha256` together from the real
  tarball and refuses if the script's, requested, or in-tarball versions
  disagree. It is the ONE sha256 implementation.
- The formula installs `templates/` into `pkgshare`.

## Why

No dependencies is load-bearing on the Bash 3.2 rule. On the release commit the
formula still names the previous tag until the `formula` job moves it;
requiring equality blocked every release.

## How

`cmd_install` refuses inside a Homebrew prefix (`/opt/homebrew/*`, `*/Cellar/*`,
`/home/linuxbrew/*`); `src -ef dest` catches Intel's `/usr/local/bin`.
