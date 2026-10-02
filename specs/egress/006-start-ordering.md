---
id: EGR-06
title: "Restricted run: proxy before container, refresh after"
area: egress
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/07-restricted-egress.sh
---

# EGR-06: Restricted run: proxy before container, refresh after

## Rule

- For a restricted project `cmd_run` MUST start the proxy/egress BEFORE the
  container, and refresh the proxy again once the container exists (relays need
  their target).
- The entrypoint waits (≤20s) for the egress proxy name to resolve before
  running hooks.

## Why

On an internal network the proxy is the only route out; the first-run hook
(composer/npm/wp-cli) needs egress immediately. Starting it afterwards made
setup die with "could not resolve proxy".

## How

Starting a restricted project recreates Caddy (new relays/ports); the egress
container survives.
