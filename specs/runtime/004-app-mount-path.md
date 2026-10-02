---
id: RUN-04
title: "Per-project app mount path"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/05-app-mount.sh
  - tests/integration/04-app-path.sh
---

# RUN-04: Per-project app mount path

## Rule

- `init --app-path=/path` (or `APP_MOUNT=`) stores the mount path in
  `<project>/app_mount`; `project_app_mount` reads it (default `/app`).
- `valid_app_mount` (shared with import) rejects `:` and other unsafe values.
- ONLY the runtime container honours it (`-v $appv:$appmnt`, `-w $appmnt`,
  `-e NIXENV_APP_MOUNT`), plus the entrypoint (exports it; logins `cd` there;
  service discovery reads `$APP_MOUNT/.nixenv/sv`), `cmd_shell` and `deploy`.
- Seed/clone/build/sync helpers keep mounting the volume at a throwaway `/app`.

## Why

Matching production paths matters for some stacks. The repo lands at the volume
root regardless of where it is mounted. A `:` would smuggle mount options.

## How

`cmd_run` refuses a symlinked `app_mount` and re-validates the value.
