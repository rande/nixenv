---
id: NET-05
title: "ps and the dashboard: probed from the host, read-only, no secrets"
area: networking
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/41-dashboard.sh
  - tests/unit/07-caddyfile.sh
  - tests/integration/21-dashboard.sh
---

# NET-05: ps and the dashboard: probed from the host, read-only, no secrets

## Rule

- `ps` probes each RUNNING project container from the HOST with ONE
  `$ENGINE exec` running `DASHBOARD_PROBE`, which uses base-Debian tools only
  (RUN-13): `/proc/net/tcp{,6}` for LISTEN sockets, `ls -lq /proc/*/fd` +
  `/proc/*/comm` for the owning process, `~/.nixenv-sv/*/supervise/stat` for
  services. The probe never runs from a container, and no container gets the
  engine socket.
- The probe output is untrusted (it comes from project code). `dashboard_parse_probe`
  keeps only parsed fields: hex addresses decoded, names limited to
  `[A-Za-z0-9._+-]` and capped in length, at most 64 ports and 64 services. A
  process named like a section marker MUST NOT switch sections. The parser
  drops the in-container sshd (`$SSHD_PORT`), the loopback proxy relays (80/443),
  and root-owned sockets: project containers run no root process (RUN-01), so
  these belong to the engine, e.g. Docker's DNS on 127.0.0.11.
- Egress hits are read from the tail of the squid log, matched on the client
  address against the project's subnet as a CIDR, never by text prefix.
- The scan writes `$DASHBOARD_DIR` (`~/.nixenv/proxy/www`): static
  `index.html`/`style.css`/`app.js` plus `status.json`. Each file is written to
  a temp file and `mv`ed into place. The directory is bind-mounted, so it is
  never replaced.
- Caddy serves it on the BARE `$PROXY_DOMAIN` (a separate site block, ahead of
  the wildcard) from `/www` (mounted `:ro`), with no directory listing, a strict
  CSP (`default-src 'none'`, `script-src 'self'`, `style-src 'self'`, no
  inline code), `nosniff` and `no-store`. Requests from any restricted
  project's subnet get a 403.
- Each project card is anchored `id="project-<name>"` (name already checked
  against the project-name pattern) with its title as a permalink, so
  `https://<domain>/#project-<p>` (`dashboard_project_url`) opens on it: the
  page validates the hash, scrolls to the card ONCE per navigation (not on the
  5 s re-render) and highlights it. `start` prints that link.
- The page renders data with `textContent` only, never `innerHTML`/`eval`. It
  rebuilds proxy URLs from validated parts and has NO action endpoints.
- A captured project's card links its mitmweb UI
  (`<p>-mitm.<domain>/#/flows?s=~comment <p>`), WITHOUT the token. The token
  is the UI password: `capture <p> web` prints the full URL.
- The page's static *02 · Commands* section documents every command `main`
  dispatches; the unit test fails when one is missing.
- A static *03 · New project* section explains how to bring an existing repo
  in (`init <url>` → `flake.nix` at the root → `build [--dir]` → `allow` →
  `start`/`ssh`, plus the repo's `.nixenv/` overrides), after two notes: the
  flake is built only from the HOST (the store is read-only in a project
  container, which never gets the engine socket), and everything runs as the
  non-root `app` user (no sudo/apt; tools from the flake or `~/.local/bin`). Inside step 2 (between
  steps 2 and 3) a `<details>`, COLLAPSED by default, shows the model
  `flake.nix`: `dashboard_model_flake`, a verbatim copy of `templates/flake.nix`
  (they MUST stay identical, TPL-14), HTML-escaped by
  `html_escape` at write time, never injected. A Copy button (hidden without
  JS) uses the clipboard API and falls back to selecting the text.
- `status.json` holds nothing secret: no tokens, no credentials, no capture UI
  token, and `deploy_hosts` only as a count. `extra-parameters` is shown with
  every environment VALUE redacted (`-e NAME=…`, `--env NAME=…`, `--env=NAME=…`,
  `-eNAME=…`; names kept), and a symlinked file is ignored. That file is where
  `-e API_TOKEN=…` ends up.
- `run`, `stop`, `proxy up` and `proxy reload` call `dashboard_refresh`. It is
  best effort and silent, and can never make those commands fail. `run`
  refreshes ONCE: its inner `cmd_proxy up` gets `DASHBOARD_REFRESH=0`.
- `run` also leaves ONE detached refresher (`dashboard_refresh_later`). It
  rescans at each `NIXENV_DASHBOARD_DELAYS` mark (default `10 30 90` seconds
  after the start; empty = off) and then exits. A newer refresher supersedes it
  through the token file `$PROXY_DIR/.dashboard-refresh`, never by `kill`: a
  recycled pid must never be signalled. The refresher ignores SIGHUP and
  holds no terminal fds. No other background probing exists; `ps --watch [N]`
  is the opt-in loop.

## Why

nixenv knows the ports a project DECLARES, not the ones a dev server actually
opened. A dev server bound to `127.0.0.1` (a 502 through the proxy, TPL-08) is
only visible from inside the container.

The engine socket would give root on the host to whatever holds it: that rules
out probing from the proxy and off-the-shelf dashboards that discover containers
through it. Self-reporting containers would be a writable channel between
projects, carrying data that project code chooses.

The page is readable by the host browser and by unrestricted projects, which
share `nixenv_net` and see each other anyway. Restricted projects may only see
themselves (NET-04). Any web page you visit can send requests to
`$PROXY_DOMAIN`, hence no actions. DNS rebinding is harmless: Caddy only serves
this site for the `$PROXY_DOMAIN` Host and SNI.

## How

`cmd_ps [--json] [--watch [N]]` → `write_dashboard` → `dashboard_scan` (sets
`DASH_JSON`, `DASH_TABLE`, `DASH_GWARNS`). Delayed refreshes exist because a container that has
just started has setup hooks (composer, npm, a first database init) and runit
services still on their way up, so the scan done right after `run` shows no
ports. Warnings carry the `@NIXENV@`
placeholder, which becomes `$0` in the terminal and `nixenv` on the page.
`container_needs_recreate` lines are reused as warnings. A proxy created before
the `/www` mount has no site for the bare domain, and Caddy answers an
unmatched host with an EMPTY 200, which shows as a blank page. That lasts until
`proxy up`. `run` leaves a running proxy alone (recreating it would cut relayed
sessions), so `run`, `ps` and `proxy reload` all detect it
(`proxy_serves_dashboard`) and say `proxy up`. The page shares `docs/index.html`'s paper/blueprint
sheets; the chosen sheet is remembered in `localStorage` (best effort), and the
page polls `status.json` every 5 s.
