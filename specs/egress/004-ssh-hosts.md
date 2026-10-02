---
id: EGR-04
title: "Port 22 only to declared git hosts"
area: egress
security: SEC-11
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/08-egress-config.sh
---

# EGR-04: Port 22 only to declared git hosts

## Rule

- When `<project>/ssh_hosts` exists, CONNECT to port 22 is allowed only to the
  hosts in it (re-validated with `normalize_allowed_host`); an empty file denies
  port 22 entirely. No file = every allowed host (old behaviour).
- `init` writes it with the forge host.

## Why

ssh to an arbitrary allowed host is a tunnel for anything.

## How

`ssh_hosts` travels in exports (re-validated on import).
