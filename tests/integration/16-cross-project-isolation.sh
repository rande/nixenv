#!/usr/bin/env bash
# SEC-06: a restricted project may reach only its OWN web services through the
# proxy (Caddy + the port relays), unless the target opts in via accept-from.
# The host keeps reaching everything.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
require_store_bin caddy
require_store_bin socat
command -v curl >/dev/null 2>&1 || skip "curl not installed"

mkproj a                      # restricted (default)
mkproj b
echo 8000 > "$NIXENV_PROJECTS_DIR/b/ports"   # also relayed by the proxy
nx run a >/dev/null
nx run b >/dev/null
wait_tcp "$PROXY_HTTPS_PORT" 20 || fail "proxy https port not listening"

# The generated Caddyfile must be accepted by the REAL caddy — the unit test
# only checks text.
out="$("$E" exec nxt-proxy "$PROFILE_PATH/bin/caddy" validate \
        --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)" \
  || fail "caddy rejected the generated Caddyfile: $out"

# Tiny HTTP backend on :8000 in each project (base has no python; socat does).
serve() {
  "$E" exec -d "nxt-$1" "$PROFILE_PATH/bin/socat" TCP-LISTEN:8000,fork,reuseaddr \
    SYSTEM:"printf 'HTTP/1.0 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\n$1-OK'"
}
serve a; serve b; sleep 2

# From inside a: curl sends *.localhost to 127.0.0.1 → loopback relay → proxy.
from_a() { dexec a "$PROFILE_PATH/bin/zsh" -lc "curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' $1 || true"; }
assert_eq "$(from_a "https://a-8000.nixenv.localhost/")" "200" "a reaches its own URL"
assert_eq "$(from_a "https://b-8000.nixenv.localhost/")" "403" "a is refused b's URL"

# The host is never guarded.
body="$(curl -ks --resolve "b-8000.nixenv.localhost:$PROXY_HTTPS_PORT:127.0.0.1" \
         "https://b-8000.nixenv.localhost:$PROXY_HTTPS_PORT/")"
assert_contains "$body" "b-OK" "host reaches b through the proxy"

# Relays: b's port 8000 is relayed by the proxy on the host side only.
wait_tcp 8000 15 || fail "b's relayed port not reachable from the host"
code="$(dexec a "$PROFILE_PATH/bin/zsh" -lc \
  "curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' http://nxt-proxy:8000/ || true")"
[ "$code" = 200 ] && fail "a reached b's service through the proxy's port relay"

# Opt-in: b accepts a → hot reload, no proxy recreate.
proxy_id="$("$E" inspect nxt-proxy --format '{{.Id}}')"
echo a > "$NIXENV_PROJECTS_DIR/b/accept-from"
nx proxy reload >/dev/null || fail "proxy reload failed"
assert_eq "$("$E" inspect nxt-proxy --format '{{.Id}}')" "$proxy_id" "reload did not recreate the proxy"
assert_eq "$(from_a "https://b-8000.nixenv.localhost/")" "200" "accept-from lets a reach b"
true
