---
id: CAP-02
title: "Ingress capture routed by Caddy through mitmproxy"
area: capture
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/37-capture.sh
  - tests/capture_addon_test.py
---

# CAP-02: Ingress capture routed by Caddy through mitmproxy

## Rule

- Ingress listener `CAPTURE_INGRESS_BASE+n` binds the egress container's
  `EGRESS_NET` address. Caddy routes `@cap_X` (inside `route{}`, after the
  SEC-06 denies, before the generic route) with `forward_proxy_url
  http://$EGRESS_LINK:<port>`, setting `X-Nixenv-Upstream <prefix>-X:<port>`
  (overwriting any client value).
- The addon routes on that header, accepts only that project's container,
  restores the public Host, and kills ingress connections not from the link
  subnet.

## Why

Caddy sends the PUBLIC host as the proxy target, not the upstream.

## How

`capture.conf` (`egress|ingress <p> <port> [container]`, `link <subnet>`) drives
both `egress.sh` and the addon `nixenv_capture.py`.
