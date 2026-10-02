---
paths:
  - "nixenv.sh"
---

# Egress rules (Restricted-by-default egress through squid)

These rules are specified one per file under `specs/egress/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- EGR-01 Egress restriction is on by default: @../../specs/egress/001-restricted-by-default.md
- EGR-02 allowed_hosts: validated, exact by default: @../../specs/egress/002-allowlist.md
- EGR-03 Refused names are never resolved: @../../specs/egress/003-refused-names-never-resolved.md
- EGR-04 Port 22 only to declared git hosts: @../../specs/egress/004-ssh-hosts.md
- EGR-05 squid runs in its own egress container: @../../specs/egress/005-egress-container.md
- EGR-06 Restricted run: proxy before container, refresh after: @../../specs/egress/006-start-ordering.md
- EGR-07 Migrate files that recorded an old egress address: @../../specs/egress/007-egress-address-migration.md
