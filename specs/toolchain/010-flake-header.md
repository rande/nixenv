---
id: TOOL-10
title: "build offers the flake header's settings, applied only on a yes"
area: toolchain
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/49-flake-header.sh
---

# TOOL-10: build offers the flake header's settings, applied only on a yes

## Rule

- `build <project>` reads the template header keys (TPL-01:
  `# nixenv:description|allow|port|app-path`) from the flake it extracted
  (`apply_flake_header`), before building.
- It offers only what differs from the project: `allow` hosts missing from
  `allowed_hosts` (each through `normalize_allowed_host`, invalid ones warned
  and dropped), and `app-path` (through `valid_app_mount`) only while the
  project has no `app_mount` of its own. An explicit `--app-path` is never
  challenged. `port` and `description` are only shown.
- Nothing is applied without an interactive yes (`confirm_tty`); there is no
  flag that skips it. Hosts go through `cmd_allow` (hot reload); a new
  app-path is written to `app_mount` and a running container is told to
  restart.
- An interactive "no" records the offered set in
  `<project>/.flake-header-declined`; the same set is then only logged, a
  different one is asked again. Without a TTY nothing is applied or recorded,
  and the warning names the `allow` command.
- A declined or failed header never stops the build.

## Why

A repo should be able to declare the hosts its setup needs, as a template
does, instead of the user discovering them in `egress <p>`. But the flake
comes from the repo: an allowed host is a place data can be SENT, and the
app path decides where the code volume is mounted. Silently applying either
would let any repo widen its own egress.

## How

`init --template` applies the same keys before its first build, so that build
finds nothing new to offer. The decline marker travels in exports like any
project file; it can only suppress the offer, never apply a setting.
