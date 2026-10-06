---
id: CAP-01
title: "mitmproxy runs behind squid, never instead of it"
area: capture
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/37-capture.sh
  - tests/integration/19-capture.sh
---

# CAP-01: mitmproxy runs behind squid, never instead of it

## Rule

- mitmproxy runs in the EGRESS container (`egress.sh`'s `capture_loop`), BEHIND
  squid: squid keeps every SEC-05/06/11 property and a refused name never
  reaches mitmproxy.
- Restricted projects only. `<project>/capture` lists directions (empty = both);
  it is NOT exported.
- Egress listener per captured project on **127.0.0.1**
  (`CAPTURE_EGRESS_BASE+n`), reached via squid `cache_peer … name=cap_X` with
  `cache_peer_access`/`never_direct allow p_X !nocapture_ports` — src+port ACLs
  only (no new DNS); `never_direct` fails CLOSED; port 22 stays direct.

## Why

Bound anywhere else, a project could use the listener as a proxy and skip
squid. An unrestricted project has no proxy in its path.

## How

`capture <p> on [egress|ingress]|off|untrust|status|web|log [-f]|tui|har|clear`.
`write_capture_files` sets `CAPTURE_CHANGED` only when `capture.conf` changes;
`egress_reload` then kills mitmproxy (pid file) and the loop restarts it.
`delete` removes the captures. Integration test 19 uses `NIXENV_TEST_PROFILE`
(a profile with mitmproxy) when the shared one predates it.
