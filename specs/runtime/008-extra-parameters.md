---
id: RUN-08
title: "Extra engine flags come from <project>/extra-parameters"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/19-extra-parameters.sh
---

# RUN-08: Extra engine flags come from <project>/extra-parameters

## Rule

- Extra engine flags MUST come from the FILE `<project>/extra-parameters`
  (like `unrestricted`/`ports`/`hosts.extra`), not a CLI flag.
- `project_extra_args` strips `#` comments and collapses whitespace;
  `cmd_run` splits the tokens into the `extra_args` array (guarded expansion),
  one argv entry per flag. Contents are passed VERBATIM — no presets or magic
  tokens.
- `write_extra_parameters` scaffolds a comments-only file from `init` and `run`
  and never clobbers an existing one.

## Why

Discoverable rather than folklore; what's in the file is exactly what the
engine receives. Flags are fixed at creation, so edits need a `run`.

## How

The commented example is the docker/podman-in-container set (`seccomp`/
`apparmor` unconfined, `label=disable`, `/dev/fuse`, `/dev/net/tun`). A device
missing on the engine host makes `run` fail; the container still runs as your
uid with no capabilities and no subuid/subgid, so nested rootless podman is
limited to one UID. Imported `extra-parameters` land inert (EXP-04).
