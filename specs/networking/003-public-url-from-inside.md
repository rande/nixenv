---
id: NET-03
title: "Public URLs work from inside a container"
area: networking
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/10-entrypoint-content.sh
  - tests/integration/06-proxy-ingress.sh
---

# NET-03: Public URLs work from inside a container

## Rule

- The entrypoint installs runit services `proxy-relay-443`/`-80` running
  `socat TCP4-LISTEN:<p>,bind=127.0.0.1,fork TCP:$NIXENV_PROXY_NAME:<p>` — a raw
  TCP relay (TLS end-to-end, SNI + Host intact). The run script `getent`s the
  proxy and `sleep 5; exit 0`s while it is absent.
- glibc clients need `127.0.0.1 <name>` in `hosts.extra` — loopback, NOT the
  proxy's IP.
- The proxy's root CA (mkcert's, or Caddy's internal exported by
  `export_caddy_ca`) is published to `~/.nixenv/proxy/certs/rootCA.pem`, mounted
  at `/etc/nixenv-proxy-ca.crt`, merged into `$HOME/.nixenv-ca-bundle.crt` and
  exported as `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
  `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, plus `NODE_EXTRA_CA_CERTS`.

## Why

curl/libcurl (and PHP ext-curl, Guzzle, Symfony HttpClient) force `localhost`
and every `*.localhost` to 127.0.0.1, ignoring `/etc/hosts` and DNS — so
loopback must genuinely reach the proxy. A former `@proxy` token was removed:
the relay is hostname-agnostic, so loopback covers every client.

## How

Plain service-to-service calls need none of this:
`http://<prefix>-<project>:<port>/` resolves directly.
