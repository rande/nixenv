---
paths:
  - "nixenv.sh"
  - "LICENSE"
  - "RELEASING.md"
  - "packaging/**"
  - ".github/workflows/**"
  - "release.sh"
  - "docs/index.html"
---

# Release rules (Versioning, Homebrew, release script, CI)

These rules are specified one per file under `specs/release/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- REL-01 NIXENV_VERSION and the GPL licence: @../../specs/release/001-version-and-license.md
- REL-02 RELEASING.md is the one release runbook: @../../specs/release/002-releasing-runbook.md
- REL-03 Homebrew formula: no dependencies, may lag the version: @../../specs/release/003-homebrew-formula.md
- REL-04 release.sh drives a release end to end, offline-testable: @../../specs/release/004-release-script.md
- REL-05 CI and release workflows: @../../specs/release/005-ci-workflows.md
