---
id: EXP-01
title: "Export archive format"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
  - tests/integration/14-export-import.sh
---

# EXP-01: Export archive format

## Rule

- `export <p> [file] [--with-home] [--force]` writes a plain `.tar` (NOT
  gzipped) containing `nixenv-export/{manifest,meta/,volumes/{app,databases[,home][,deploy]}.tar.gz}`
  (`deploy` = the deploy state volume when it exists, DEP-05).
- The shared Nix store is never included (gigabytes; reproducible by `build`).
- `export` refuses on a running project unless `--force`.
- `manifest_get` parses with `sed`, never `source`; the project name from it is
  validated exactly as `init` would before becoming a path or container name.

## Why

Each volume is already gzipped; compressing twice costs time for nothing. A
live database tars crash-consistent at best. The manifest comes from an archive
we didn't create.

## How

`import <file> [new-name] [--force]`. The manifest records `home=0|1` and `deploy=0|1`.
