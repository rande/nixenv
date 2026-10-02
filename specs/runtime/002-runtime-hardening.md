---
id: RUN-02
title: "Runtime hardening on every nixenv container"
area: runtime
security: SEC-07
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/30-runtime-hardening.sh
  - tests/integration/17-security-hardening.sh
---

# RUN-02: Runtime hardening on every nixenv container

## Rule

- `container_hardening_args` (`--cap-drop=ALL`,
  `--security-opt=no-new-privileges`, `--pids-limit=${NIXENV_PIDS_LIMIT:-4096}`,
  0 = none) MUST be applied to project, proxy, egress and deploy containers.
- In `cmd_run` the `harden` array goes BEFORE `extra_args`, so a deliberate
  override in `extra-parameters` wins.
- Nothing may need a capability: low ports and ping come from sysctls
  (`net.ipv4.ip_unprivileged_port_start=0`, `net.ipv4.ping_group_range`).

## Why

Defence in depth for untrusted project code.

## How

Containers created before hardening keep their old settings until recreated.
