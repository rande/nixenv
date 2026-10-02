---
paths:
  - "nixenv.sh"
---

# Toolchain rules (The shared Nix store, project flakes, PATH)

These rules are specified one per file under `specs/toolchain/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- TOOL-01 The base flake ships no language runtimes: @../../specs/toolchain/001-base-flake-no-runtimes.md
- TOOL-02 build resets the shared profile before installing: @../../specs/toolchain/002-shared-profile-reset.md
- TOOL-03 zmx is a pinned prebuilt binary: @../../specs/toolchain/003-zmx-pinned-prebuilt.md
- TOOL-04 Project flakes are untrusted: @../../specs/toolchain/004-project-flakes-untrusted.md
- TOOL-05 build --dir is remembered per project: @../../specs/toolchain/005-flake-dir-remembered.md
- TOOL-06 PATH order: ~/.local/bin, project profile, base: @../../specs/toolchain/006-path-order.md
- TOOL-07 Optional GitHub token for flake inputs: @../../specs/toolchain/007-github-token.md
- TOOL-08 Claude CLI from nixpkgs-unstable on the shared profile: @../../specs/toolchain/008-claude-cli.md
