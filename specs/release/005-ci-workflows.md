---
id: REL-05
title: "CI and release workflows"
area: release
applies-to:
  - ".github/workflows/**"
enforced-by:
  - tests/unit/22-workflows.sh
---

# REL-05: CI and release workflows

## Rule

- `ci.yml` runs the unit suite on push/PR on ubuntu AND macos.
- `release.yml` fires only on `v[0-9]+.[0-9]+.[0-9]+` tags: `verify` (tag ==
  `NIXENV_VERSION`, `bash -n`, unit suite, `--version`) → `release`
  (`gh release create --generate-notes`, attaching `nixenv.sh` + `LICENSE`) →
  `formula` (runs `update-formula.sh`, commits, pushes to the tap; skips with a
  `::notice::` when `TAP_TOKEN` is unset, gated by a step output).
- `actions/checkout` MUST be v5+. No `sha256sum`/`shasum` in workflows.
- The workflow test MUST NOT require PyYAML: checks are textual (`job_needs`
  awk helper, scalar `needs:` only); `yaml.safe_load` is a bonus when present.

## Why

macOS is what exercises Bash 3.2. v4 checkout forces node20→node24 warnings.
GitHub's macOS python3 has no `yaml`. Secrets aren't available in a job-level
`if`. `GITHUB_TOKEN` can't push to another repo.

## How

The formula job calls the same script you'd run locally.
