#!/usr/bin/env bash
# 'nixenv ps' probes the ports a project ACTUALLY listens on (from the host,
# via engine exec) and the proxy serves the dashboard at https://<domain>/ —
# to the host, never to a restricted project (NET-05).
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
require_store_bin caddy
require_store_bin socat
command -v curl >/dev/null 2>&1 || skip "curl not installed"

mkproj open --unrestricted
mkproj locked                 # restricted (default)
nx run open >/dev/null
nx run locked >/dev/null
wait_tcp "$PROXY_HTTPS_PORT" 20 || fail "proxy https port not listening"

out="$("$E" exec nxt__proxy "$PROFILE_PATH/bin/caddy" validate \
        --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)" \
  || fail "caddy rejected the generated Caddyfile: $out"

# One port on every interface, one on loopback only.
"$E" exec -d nxt-open "$PROFILE_PATH/bin/socat" TCP-LISTEN:8000,fork,reuseaddr \
  SYSTEM:"printf 'HTTP/1.0 200 OK\\r\\n\\r\\nopen-OK'"
"$E" exec -d nxt-open "$PROFILE_PATH/bin/socat" TCP-LISTEN:5999,bind=127.0.0.1,fork,reuseaddr SYSTEM:true
sleep 2

table="$(nx ps)" || fail "ps failed: $table"
assert_contains "$table" "8000  socat  https://open-8000.nixenv.localhost:$PROXY_HTTPS_PORT/" "listening port + its URL"
assert_contains "$table" "5999  socat  (127.0.0.1 only" "loopback-only port flagged"
assert_not_contains "$table" " 2222 " "the in-container sshd is not listed"

json="$(nx ps --json)" || fail "ps --json failed"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
p = {x["name"]: x for x in d["projects"]}
assert p["open"]["state"] == "running" and p["locked"]["restricted"] is True
assert 8000 in [l["port"] for l in p["open"]["listening"]]
assert any(s["name"] == "sshd" and s["state"] == "run" for s in p["open"]["services"])
assert d["proxy"]["serves_dashboard"] is True
' || fail "ps --json content"
fi

# The host reads the page and its data.
get() { curl -ks --resolve "nixenv.localhost:$PROXY_HTTPS_PORT:127.0.0.1" -o /dev/null -w '%{http_code}' \
          "https://nixenv.localhost:$PROXY_HTTPS_PORT/$1"; }
assert_eq "$(get '')" "200" "dashboard served on the bare domain"
assert_eq "$(get status.json)" "200" "status.json served"
assert_eq "$(get app.js)" "200" "app.js served"
assert_eq "$(get nope/)" "404" "no directory listing / no other files"
csp="$(curl -ksI --resolve "nixenv.localhost:$PROXY_HTTPS_PORT:127.0.0.1" "https://nixenv.localhost:$PROXY_HTTPS_PORT/")"
assert_contains "$csp" "default-src 'none'" "CSP header"

# A restricted project may not read it (it lists every project); an
# unrestricted one shares the flat network anyway and may.
in_c() { dexec "$1" "$PROFILE_PATH/bin/zsh" -lc "curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' https://nixenv.localhost/status.json || true"; }
assert_eq "$(in_c locked)" "403" "restricted project is refused the dashboard"
assert_eq "$(in_c open)" "200" "unrestricted project reaches it"

# A service that starts listening AFTER 'run' returns shows up without another
# command: run leaves a delayed refresher behind.
nx stop open >/dev/null
NIXENV_DASHBOARD_DELAYS="4" nx run open >/dev/null
grep -q '"port":8100' "$PROXY_DIR/www/status.json" && fail "nothing listens on 8100 yet"
"$E" exec -d nxt-open "$PROFILE_PATH/bin/socat" TCP-LISTEN:8100,fork,reuseaddr SYSTEM:true
i=0; until grep -q '"port":8100' "$PROXY_DIR/www/status.json" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -le 10 ] || fail "the delayed refresh never picked up port 8100"
  sleep 1
done

# stop refreshes it.
nx stop open >/dev/null
grep -q '"name":"open","state":"stopped"' "$PROXY_DIR/www/status.json" || fail "stop refreshed status.json"
