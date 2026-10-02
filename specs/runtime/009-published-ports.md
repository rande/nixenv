---
id: RUN-09
title: "Extra published ports in <project>/ports"
area: runtime
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/integration/10-expose-delete.sh
---

# RUN-09: Extra published ports in <project>/ports

## Rule

- One port per line in `<project>/ports` (`expose` appends). A bare number maps
  `127.0.0.1:N:N`; a `:`-spec is passed to `-p` verbatim.
- The SSH port is always published on `127.0.0.1`.
- Restricted projects publish nothing themselves; the proxy publishes and
  relays their ports (EGR-01); address specs (`a:b:c`) are unsupported there.

## Why

Loopback by default: nothing is exposed to the network unless asked.

## How

`expose` restarts a running project to apply.
