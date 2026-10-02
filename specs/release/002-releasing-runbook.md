---
id: REL-02
title: "RELEASING.md is the one release runbook"
area: release
applies-to:
  - "RELEASING.md"
  - "packaging/**"
  - ".github/workflows/**"
enforced-by:
  - tests/unit/22-workflows.sh
---

# REL-02: RELEASING.md is the one release runbook

## Rule

- `RELEASING.md` is canonical (setup, tag flow, bad-tag recovery, manual
  fallback, numbering). `packaging/homebrew/README.md` points at it.
- It MUST name all three workflow jobs, `NIXENV_VERSION` and `TAP_TOKEN`, and its
  tag pattern MUST be byte-identical to `release.yml`'s trigger.

## Why

A stale runbook is worse than none, because it gets followed.

## How

Release order: bump `NIXENV_VERSION` → commit → tag → `update-formula.sh` (the
sha256 can't exist before the tag) → copy into the tap.
