---
id: RUN-16
title: "Memory and CPU limits come from <project>/limits"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/51-limits.sh
---

# RUN-16: Memory and CPU limits come from <project>/limits

## Rule

- `limits <p> [memory=<size>] [cpus=<n>] | off` writes `<project>/limits`
  (`memory=`/`cpus=` lines, `#` comments; the last line for a key wins). With
  no argument it shows the limits. `key=` with an empty value removes that
  key; `off` removes the file. It restarts a running project, like `expose`.
- Values MUST pass `valid_limit`: memory is a number with an optional
  `b/k/m/g` unit, cpus a decimal above 0. `cmd_limits` refuses an invalid one;
  `project_limit` warns and ignores one found in the file.
- `cmd_run` passes them as `--memory`/`--cpus` AFTER the hardening flags and
  BEFORE `extra_args`, so a flag in `extra-parameters` still wins. No limit
  is set by default.
- The container gets the label `nixenv.limits=<summary>`
  (`project_limits_summary`); `container_needs_recreate` warns when a running
  container's label differs from the file (no label = no limits).
- `cmd_run` and `cmd_limits` refuse a symlinked `limits`. The file travels in
  exports; import keeps only valid `memory=`/`cpus=` lines.

## Why

One project's runaway build or database must not starve the others or the
engine VM. `extra-parameters` could already carry `--memory`, but a validated
command is discoverable and makes a stale running container visible.

## How

Both docker and podman accept `--memory`/`--cpus`. Rootless podman needs the
`memory` and `cpu` cgroup v2 controllers delegated to the user (systemd's
default on current distros); on cgroup v1 rootless podman ignores the limits.
Swap follows the engine default (`--memory-swap` via `extra-parameters`).
