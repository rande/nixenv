#!/usr/bin/env bash
# Reverse proxy: hostname scheme routes to the project; no-route → 502 text.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
require_store_bin caddy
command -v curl >/dev/null 2>&1 || skip "curl not installed"

mkproj p1 --unrestricted
nx run p1 >/dev/null              # auto-starts nxt-proxy on test ports
wait_tcp "$PROXY_HTTPS_PORT" 20 || fail "proxy https port not listening"

# backend: python http server on :3000 inside the project
"$E" exec -d nxt-p1 "$PROFILE_PATH/bin/python3" -m http.server 3000 --bind 0.0.0.0
sleep 2

url="https://p1-3000.nixenv.localhost:$PROXY_HTTPS_PORT/"
body="$(curl -ks --resolve "p1-3000.nixenv.localhost:$PROXY_HTTPS_PORT:127.0.0.1" "$url")" \
  || fail "routed request failed"
assert_contains "$body" "Directory listing" "request reached the project backend"

# forwarded headers visible to the backend?  (python http.server logs only —
# verify via a header echo using python instead)  no-route case:
code_body="$(curl -ks --resolve "nope.nixenv.localhost:$PROXY_HTTPS_PORT:127.0.0.1" \
  "https://nope.nixenv.localhost:$PROXY_HTTPS_PORT/")"
assert_contains "$code_body" "no route" "502 fallback text"

nx proxy status | grep -q "proxy running" || fail "proxy status"
