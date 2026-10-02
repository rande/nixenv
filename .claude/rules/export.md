---
paths:
  - "nixenv.sh"
---

# Export / import rules (Moving and backing up projects)

These rules are specified one per file under `specs/export/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- EXP-01 Export archive format: @../../specs/export/001-archive-format.md
- EXP-02 The whole project dir travels, except what is regenerated: @../../specs/export/002-project-files-travel.md
- EXP-03 Machine-specific state is regenerated on import: @../../specs/export/003-regenerated-on-import.md
- EXP-04 Imported meta files are untrusted: @../../specs/export/004-imported-meta-untrusted.md
- EXP-05 The home volume is opt-in: @../../specs/export/005-home-volume-opt-in.md
- EXP-06 Tokens embedded in the app volume are refused: @../../specs/export/006-git-token-in-app-volume.md
- EXP-07 Progress meter only for export/import tars: @../../specs/export/007-progress-reporting.md
