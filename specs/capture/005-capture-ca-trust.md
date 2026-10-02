---
id: CAP-05
title: "Capture CA trust is explicit and sticky until untrust"
area: capture
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/37-capture.sh
---

# CAP-05: Capture CA trust is explicit and sticky until untrust

## Rule

- `cmd_run` mounts mitmproxy's CA at `/etc/nixenv-capture-ca.crt` only when
  `capture_ca_trusted`: egress capture on, OR the `<project>/capture-trust`
  marker that `capture on` writes. `capture untrust` + restart revokes it (not
  exported).
- `cmd_run` waits for the CA (`capture_wait_ca`) only while capturing.
- The entrypoint merges every extra CA into the bundle and ONE
  `NODE_EXTRA_CA_CERTS` file.

## Why

Trust is fixed at container creation and a restart kills whatever runs inside
(a Claude session), so only the FIRST capture restarts — a deliberate dev-only
trade-off.

## How

mitmproxy writes `egress-data/mitmproxy/mitmproxy-ca-cert.pem` on first start.
