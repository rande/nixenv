---
id: CAP-04
title: "mitmweb UI only through Caddy, with a token"
area: capture
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/37-capture.sh
---

# CAP-04: mitmweb UI only through Caddy, with a token

## Rule

- mitmweb's `web_host` is the link address (never project-facing); the password
  is `egress-data/mitmweb.token` (`capture web` prints `?token=`).
- NOT host-published: Caddy serves it as `<p>-mitm.<domain>` (`@capui_X` in
  `caddy_capture_routes` → `$EGRESS_LINK:CAPTURE_WEB_IN_PORT`, Host kept).

## Why

mitmweb's websocket compares Origin to Host. Restricted projects can't open it
(the SEC-06 guard admits only `<self|peer>-<digits>`), so only the host and
unrestricted projects reach it, and the token stands.

## How

`capture_ui_url` adds `#/flows?s=~comment <p>`. `egress_up` recreates an egress
container still publishing the old 8081.
