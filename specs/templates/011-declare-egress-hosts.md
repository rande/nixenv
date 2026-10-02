---
id: TPL-11
title: "Declare every host setup needs; a clean log proves nothing"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
---

# TPL-11: Declare every host setup needs; a clean log proves nothing

## Rule

- Templates are egress-restricted by default: declare every host setup needs in
  `# nixenv:allow`.
- Apps that ignore `HTTP(S)_PROXY` or pre-resolve hosts MUST be configured to use
  `$NIXENV_EGRESS_PROXY` explicitly.

## Why

Missing entries surface as `TCP_DENIED` in `egress <p>`. But a restricted
container has no outside DNS: an app that resolves the host itself fails
without ever reaching squid. WordPress ignores the proxy env (needs
`WP_PROXY_*`) and pre-resolves "safe" downloads, so its template ships a
must-use plugin skipping that check when a proxy is set.

## How

The metadata is seeded into `allowed_hosts` before the build.
