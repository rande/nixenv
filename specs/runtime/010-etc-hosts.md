---
id: RUN-10
title: "Custom /etc/hosts is rebuilt by the entrypoint"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/05-hosts-extra.sh
---

# RUN-10: Custom /etc/hosts is rebuilt by the entrypoint

## Rule

- MUST NOT use `--add-host` (can't change on a live container; ignored with a
  bind-mounted `/etc/hosts`).
- `cmd_run` always bind-mounts a writable host file `<project>/etc-hosts` at
  `/etc/hosts`; the entrypoint rebuilds it each start (guarded by
  `[ -w /etc/hosts ]`): base localhost lines + `127.0.1.1 <hostname>` + the
  project profile's `etc/hosts.extra` + the host-side `<project>/hosts.extra`
  (mounted at `/etc/hosts.extra:ro`), in that order.

## Why

Rebuild-not-append keeps it idempotent. It replaces the engine's container-IP
line with `127.0.1.1 <hostname>`.

## How

`host <project> <name:ip>…` appends `ip<TAB>name` lines (literal IPs only) to
`hosts.extra`; flake entries are the versioned/team-shared path. `$hostsmount`
is an array of `-v` args.
