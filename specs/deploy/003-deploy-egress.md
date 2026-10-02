---
id: DEP-03
title: "deploy egress: allowed_hosts + deploy_hosts on its own network"
area: deploy
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/38-deploy.sh
  - tests/integration/20-deploy.sh
---

# DEP-03: deploy egress: allowed_hosts + deploy_hosts on its own network

## Rule

- The deploy container sits on its own `--internal` network `deploy_net`.
  Squid gives it `deploy_allowlist` = the project's `allowed_hosts` +
  `<project>/deploy_hosts` (deduplicated), via `deploysrc_X`/`deploydst_X` ACLs
  keyed by the deploy subnet, in the same gate → `to_localnets` → allow order.
  Port 22 is open to every listed host (no `ssh_hosts` limit).
- Deploy egress is enabled by the `deploy_hosts` FILE existing; no file = no
  egress connection = no network.
- Production hosts belong in `deploy_hosts` only. `deploy <p> allow` normalises,
  refuses symlinks, and skips hosts already in `allowed_hosts`.

## Why

The dev container must not reach production even if it got hold of a
credential; the deploy container needs everything the dev one does plus
production.

## How

`write_egress_configs` fills `EGRESS_DEPLOYS`; `egress_up` keeps squid running
for deploy-only setups; `egress_connect_nets` joins the deploy nets.
