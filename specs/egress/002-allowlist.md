---
id: EGR-02
title: "allowed_hosts: validated, exact by default"
area: egress
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/09-allow-restrict.sh
  - tests/unit/32-egress-notes.sh
---

# EGR-02: allowed_hosts: validated, exact by default

## Rule

- `<project>/allowed_hosts` holds hosts one per line. Every entry goes through
  `normalize_allowed_host`: `*.foo` → `.foo` (subdomains), a bare name stays
  EXACT, schemes/ports/paths rejected.
- `init` seeds the forge host (`forge_host_from_url`); `init --allow=a,b`
  (repeatable) and `allow <p> <host>…` add more.
- `allow` HOT-reloads squid (`squid -k reconfigure`), never recreating a proxy.
- `egress_allowlist_notes` warns about wildcards and forge hosts (any repo there
  is an exit for data) and suggests `ssh_hosts`.

## Why

A bare name allowing every subdomain would include hosts other people control.

## How

`egress <p> [-f]` summarises allowed vs `TCP_DENIED` from the squid log at
`~/.nixenv/proxy/egress-data/egress.log` (falls back to `proxy/data/egress.log`),
filtered by the project's subnet.
