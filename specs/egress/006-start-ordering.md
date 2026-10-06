---
id: EGR-06
title: "Restricted run: proxy before container, refresh after"
area: egress
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/07-restricted-egress.sh
  - tests/unit/42-proxy-refresh.sh
---

# EGR-06: Restricted run: proxy before container, refresh after

## Rule

- For a restricted project `cmd_run` MUST start the proxy/egress BEFORE the
  container, and refresh the proxy again once the container exists (relays need
  their target).
- That refresh MUST hot-reload (`cmd_proxy reload`) a running proxy whose
  `nixenv.proxy-start` label (`proxy_start_sum`: `start.sh` relays, published
  ports, cert flag) matches the freshly generated config; it recreates Caddy
  (`cmd_proxy up`) only when that differs, the label is missing, the proxy
  predates the dashboard mount, or the reload fails.
- A capture change detected by the pre-check pass (`CAPTURE_PENDING`) MUST
  still restart mitmproxy in the pass that follows.
- The entrypoint waits (≤20s) for the egress proxy name to resolve before
  running hooks.

## Why

On an internal network the proxy is the only route out; the first-run hook
(composer/npm/wp-cli) needs egress immediately. Starting it afterwards made
setup die with "could not resolve proxy".

## How

Relays are generated for every restricted project, running or not, and socat
resolves the target per connection, so restarting a known project changes
nothing fixed at the proxy's creation: recreating Caddy there only cut every
relayed ssh/zmx session. A newly restricted project or a `ports` edit still
recreates it; the egress container survives either way.
