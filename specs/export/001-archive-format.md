---
id: EXP-01
title: "Export archive format"
area: export
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/23-export-import.sh
  - tests/unit/27-import-hostile-meta.sh
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
Import unpacks the whole archive first into a `mktemp -d` stage under
`IMPORT_DIR` (`~/.nixenv/import`, mode 700, following `$HOME`), never `/tmp`:
that is often a small tmpfs (half the RAM on Debian 13) and a `--with-home`
archive is gigabytes. It checks the free space there against the archive's size and, when `tar` fails,
shows tar's own last lines (truncated copy, full disk, not a tar) instead of a
bare "could not extract".
The outer tar runs with `COPYFILE_DISABLE=1`: macOS tar otherwise adds a
`._<file>` AppleDouble entry and an xattr header per file, which Linux tar
warns about one by one. Import skips `._*` files in `meta/`, so archives made
before this don't leave that junk in the project dir.
