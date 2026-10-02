# Core rules (How the script is built and run)

These rules are specified one per file under `specs/core/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- CORE-01 nixenv.sh is self-contained: @../../specs/core/001-single-file-source-of-truth.md
- CORE-02 Embedded heredocs: quoted, unique delimiters, deliberate escapes: @../../specs/core/002-embedded-heredocs.md
- CORE-03 Docker and podman through $ENGINE: @../../specs/core/003-engine-abstraction.md
- CORE-04 Bash 3.2 for nixenv.sh, POSIX sh for the entrypoints: @../../specs/core/004-shell-portability.md
- CORE-05 Use ./nixenv.sh in the repo; README uses bare nixenv: @../../specs/core/005-invoke-checkout-script.md
- CORE-06 All engine-side names derive from CONTAINER_PREFIX: @../../specs/core/006-prefix-naming.md
- CORE-07 help, version, install run before materialize_context: @../../specs/core/007-early-dispatch.md
- CORE-08 Never commit or casually destroy ~/.nixenv/projects: @../../specs/core/008-user-data-safety.md
