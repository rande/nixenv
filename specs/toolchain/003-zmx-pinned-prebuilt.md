---
id: TOOL-03
title: "zmx is a pinned prebuilt binary"
area: toolchain
security: SEC-09
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/26-pinned-fetches.sh
---

# TOOL-03: zmx is a pinned prebuilt binary

## Rule

- zmx MUST be installed as a prebuilt static-musl binary (`pkgs.fetchurl` +
  `runCommand`), pinned by `zmxVersion` and one sha256 per system in
  `zmxHashes`, release URL first and zmx.sh as mirror.
- The base build MUST stay pure: no `builtins.fetchTarball`, no `--impure`, and
  every system in `systems` has a hash.
- Upgrading = bump the version AND all hashes (see RELEASING.md).

## Why

zmx's source build needs bubblewrap/user namespaces the builder can't create;
an unpinned download would let a swapped upstream tarball into every project.

## How

`BUILDER_PRIVILEGED=1` runs the builder `--privileged` as a fallback for other
source builds that need bwrap.
