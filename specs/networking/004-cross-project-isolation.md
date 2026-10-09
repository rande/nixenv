---
id: NET-04
title: "Restricted projects cannot reach other projects through the proxy"
area: networking
security: SEC-06
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/07-caddyfile.sh
  - tests/integration/16-cross-project-isolation.sh
---

# NET-04: Restricted projects cannot reach other projects through the proxy

## Rule

- `write_egress_configs` records `EGRESS_SUBNETS`; `caddy_isolation_rules`
  emits, per restricted project, `@xproj_<id>` = `remote_ip <subnet>` AND
  `not header_regexp Host ^(<self>|<peers>)-[0-9]+<suffix>…$`, where
  `<suffix>` covers `.<domain>` and the nip.io form (NET-01) → `respond 403`.
- Peers come from the TARGET's `<target>/accept-from` (names or `*`; anything
  else dropped because it lands in a regex — `project_accept_from`).
- The denies sit inside a `route {}` block BEFORE `reverse_proxy`, so
  `cmd_proxy up` MUST call `write_egress_configs` before `write_caddyfile`.
- The proxy's socat port relays bind `RELAY_BIND` = the proxy's address inside
  `$PROXY_NET`'s subnet, chosen by `pick_addr` by SUBNET, not position.

## Why

Restricted projects reach other projects only through the proxy, so that is
where isolation is enforced. `route` keeps literal order; Caddy sorts bare
directives and `handle`s. After a restart `hostname -I` can list an internal
net first. Host requests and unrestricted projects are deliberately unguarded
(source addresses vary per engine; unrestricted projects share flat
`nixenv_net` anyway).

## How

`accept-from` travels in exports. `pick_addr_fn` emits the function
into generated scripts; it falls back to the first address.
