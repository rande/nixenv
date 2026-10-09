---
id: NET-02
title: "TLS: mkcert only if present, never a surprise prompt"
area: networking
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/07-caddyfile.sh
---

# NET-02: TLS: mkcert only if present, never a surprise prompt

## Rule

- `proxy_make_cert` uses `mkcert` ONLY if the binary is present (wildcard
  `*.PROXY_DOMAIN`, plus `proxy_nip_site` when on, into `~/.nixenv/proxy/certs`); otherwise the Caddyfile uses
  `tls internal`.
- `mkcert -install` (may prompt for a password) runs only when the CA isn't
  already present, and only after printing what it does.
  `PROXY_MKCERT_INSTALL=0` skips it; the `run` auto-start path forces `0` so
  `run` never prompts; an explicit `proxy up` defaults to `1`.
- `proxy remove-cert` deletes nixenv's cert and PRINTS the `mkcert -uninstall`
  command instead of running it.

## Why

`mkcert -uninstall` affects all of the user's certs; trust-store changes must
be explicit.

## How

`proxy renew` reissues the cert. `*.localhost` resolves to 127.0.0.1 in
Chrome/Firefox; Safari needs a hosts line.
