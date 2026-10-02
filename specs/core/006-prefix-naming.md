---
id: CORE-06
title: "All engine-side names derive from CONTAINER_PREFIX"
area: core
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/04-project-names.sh
  - tests/unit/35-dev-environment.sh
---

# CORE-06: All engine-side names derive from CONTAINER_PREFIX

## Rule

- Containers, volumes, networks and the store volume MUST derive from
  `CONTAINER_PREFIX` (default `nixenv`): project container `<prefix>-<p>`,
  volumes `<prefix>_<p>_{app,home,databases}`, `NIX_VOLUME`
  `<prefix>__nixos_store`, `PROXY_NET` `<prefix>_net`, `EGRESS_NET`
  `${PROXY_NET}-egress`.
- Helper containers that are not projects use `<prefix>__…` (double
  underscore): no project name can produce them, and `stop` with no argument
  sweeps `^<prefix>(-|__)`.
- `proxy` and `egress` are reserved project names.

## Why

Two prefixes on one engine must share nothing (the dev environment uses
`nixdev`; tests use `nxt`). A project must never be able to shadow a helper by
choosing its name.

## How

Naming helpers: `container_name`, `app_volume`, `home_volume`, `db_volume`,
`internal_net`, `deploy_container_name`, `deploy_net`; `valid_project_name`
enforces `[a-zA-Z0-9_-]`, no leading `-`, and the reserved names.
