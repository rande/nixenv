---
paths:
  - "nixenv.sh"
---

# Networking rules (Shared reverse proxy, TLS, cross-project isolation)

These rules are specified one per file under `specs/networking/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- NET-01 One shared Caddy reverse proxy for all projects: @../../specs/networking/001-shared-reverse-proxy.md
- NET-02 TLS: mkcert only if present, never a surprise prompt: @../../specs/networking/002-proxy-tls-mkcert.md
- NET-03 Public URLs work from inside a container: @../../specs/networking/003-public-url-from-inside.md
- NET-04 Restricted projects cannot reach other projects through the proxy: @../../specs/networking/004-cross-project-isolation.md
