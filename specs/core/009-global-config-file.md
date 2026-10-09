---
id: CORE-09
title: "~/.nixenv/config holds global settings, parsed and never sourced"
area: core
applies-to:
  - "nixenv.sh"
  - "tests/lib.sh"
enforced-by:
  - tests/unit/46-config.sh
---

# CORE-09: ~/.nixenv/config holds global settings, parsed and never sourced

## Rule

- `load_config` reads `NIXENV_CONFIG` (`~/.nixenv/config`, following `$HOME`)
  at the top of the script, before any setting gets its default.
- Format: `KEY=VALUE` lines; blank lines and `#` comments ignored; an optional
  `export ` prefix, blanks around `=` and one pair of matching quotes around
  the value are accepted. The file MUST NOT be sourced or evaluated: values are
  plain text.
- Only the keys in `NIXENV_CONFIG_KEYS` (the proxy settings: `PROXY_DOMAIN`,
  `PROXY_NIP_DOMAIN`, `PROXY_BIND`, `PROXY_HTTP_PORT`, `PROXY_HTTPS_PORT`,
  `PROXY_AUTOSTART`, `PROXY_MKCERT_INSTALL`) are read; anything else warns on
  stderr and is ignored.
- A variable set in the environment, even to `""`, wins over the file.
- The test harness points `NIXENV_CONFIG` at its own state dir, so a
  developer's config never reaches the suite.

## Why

Proxy settings must be the same for EVERY command: `start` rewrites the
Caddyfile and may recreate the proxy, so one shell without an exported
`PROXY_BIND`/`PROXY_NIP_DOMAIN` silently dropped a Tailscale route. Sourcing
the file would run whatever it contains; a key allowlist keeps it from
changing naming (`CONTAINER_PREFIX`) or paths used for test isolation.

## How

`printf -v` assigns the value (Bash 3.2 has it); the only `eval` tests whether
an allowlisted name is set. The usage text prints the effective values.
