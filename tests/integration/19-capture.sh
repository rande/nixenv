#!/usr/bin/env bash
# 'nixenv capture' end-to-end: mitmproxy behind squid in the egress container.
# The project trusts the capture CA and its HTTPS is recorded; squid still
# refuses unlisted names (and they are never recorded); nothing project-side can
# reach mitmproxy's listeners or UI; ingress through Caddy is recorded too.
# Needs internet access and mitmproxy in the store. NIXENV_TEST_PROFILE points
# at another profile in the store volume (one with mitmproxy) without
# rebuilding the shared one.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
PROFILE_PATH="${NIXENV_TEST_PROFILE:-$PROFILE_PATH}"
# The listener/UI port constants, read from the script under test.
eval "$(grep -E '^CAPTURE_(EGRESS_BASE|INGRESS_BASE|WEB_IN_PORT)=' "$NIXENV_SH" | sed 's/[[:space:]]*#.*//')"
EGRESS_LINK="${CONTAINER_PREFIX}__egress-link"
PROXY_DOMAIN="${PROXY_DOMAIN:-nixenv.localhost}"
export PROFILE="$PROFILE_PATH"
require_store
require_store_bin squid
require_store_bin mitmweb
require_store_bin caddy

mkproj c
nx allow c example.com >/dev/null
nx capture c on </dev/null >/dev/null || fail "capture on"
assert_eq "$(cat "$NIXENV_PROJECTS_DIR/c/capture")" "egress
ingress" "both directions by default"
nx run c >/dev/null || fail "run"

# The container was created trusting mitmproxy's CA.
"$E" inspect nxt-c --format '{{range .Mounts}}{{.Destination}} {{end}}' \
  | grep -q /etc/nixenv-capture-ca.crt || fail "capture CA not mounted"
[ -z "$("$E" port nxt-egress 2>/dev/null)" ] || fail "egress container publishes a port (the UI goes through Caddy)"

# HTTPS out is intercepted (issuer = mitmproxy) AND trusted.
out="$(dexec c "$PROFILE_PATH/bin/zsh" -lc 'curl -sv -o /dev/null -w "CODE=%{http_code}" https://example.com/ 2>&1' || true)"
assert_contains "$out" "mitmproxy" "certificate issued by mitmproxy"
case "$out" in *CODE=2*|*CODE=3*) ;; *) fail "captured HTTPS request failed: $(printf '%s' "$out" | tail -5)";; esac

logf="$PROXY_DIR/egress-data/captures/c.log"
for _ in 1 2 3 4 5; do [ -s "$logf" ] && break; sleep 1; done
assert_contains "$(cat "$logf")" "egress  GET https://example.com/" "request recorded"
[ -s "$PROXY_DIR/egress-data/captures/c.flows" ] || fail "flows file empty"
case "$(ls -l "$PROXY_DIR/egress-data/captures/c.flows" | cut -c1-10)" in -rw-------) ;; *) fail "flows not owner-only";; esac

# squid still decides first: an unlisted host is refused and never recorded.
denied="$(dexec c "$PROFILE_PATH/bin/zsh" -lc 'curl -s -o /dev/null -w %{http_code} https://google.com/ || true')"
[ "$denied" = 000 ] || [ "$denied" = 403 ] || fail "unlisted host reachable while captured (got $denied)"
assert_not_contains "$(cat "$logf")" "google.com" "refused requests never reach mitmproxy"

# Nothing on the project side reaches mitmproxy directly.
port=$((CAPTURE_EGRESS_BASE + 1)); iport=$((CAPTURE_INGRESS_BASE + 1))
code="$(dexec c "$PROFILE_PATH/bin/zsh" -lc "curl -s -o /dev/null -w %{http_code} --max-time 5 -x http://nxt-egress:$port http://example.com/ || true")"
[ "$code" = 000 ] || fail "project reached its egress listener directly (bypassing squid): $code"
code="$(dexec c "$PROFILE_PATH/bin/zsh" -lc "curl -s -o /dev/null -w %{http_code} --max-time 5 --noproxy '*' http://nxt-egress:$CAPTURE_WEB_IN_PORT/ || true")"
[ "$code" = 000 ] || fail "project reached the capture UI: $code"
code="$(dexec c "$PROFILE_PATH/bin/zsh" -lc "curl -s -o /dev/null -w %{http_code} --max-time 5 -x http://nxt-egress:$iport http://nxt-c:8000/ || true")"
[ "$code" = 000 ] || fail "project reached the ingress listener: $code"

# The UI, from Caddy's side of the link: token required.
tok="$(cat "$PROXY_DIR/egress-data/mitmweb.token")"
ui() { "$E" exec nxt-proxy "$PROFILE_PATH/bin/curl" -s -o /dev/null -w %{http_code} --max-time 5 "$@" || true; }
assert_eq "$(ui "http://$EGRESS_LINK:$CAPTURE_WEB_IN_PORT/flows")" 403 "UI refuses without the token"
assert_eq "$(ui -H "Authorization: Bearer $tok" "http://$EGRESS_LINK:$CAPTURE_WEB_IN_PORT/flows")" 200 "UI with the token"
assert_contains "$(nx capture c web)" "c-mitm.$PROXY_DOMAIN" "capture web prints the Caddy URL"
assert_contains "$(nx capture c web)" "token=$tok" "capture web prints the token"
# Through Caddy as c-mitm.<domain>: token still required.
via() { "$E" exec nxt-proxy "$PROFILE_PATH/bin/curl" -sk -o /dev/null -w %{http_code} --max-time 5 \
  --resolve "c-mitm.$PROXY_DOMAIN:443:127.0.0.1" "$@" || true; }
assert_eq "$(via "https://c-mitm.$PROXY_DOMAIN/flows")" 403 "UI via Caddy refuses without the token"
assert_eq "$(via -H "Authorization: Bearer $tok" "https://c-mitm.$PROXY_DOMAIN/flows")" 200 "UI via Caddy with the token"
# ...and never from a restricted project, even the captured one (cross-project guard).
code="$(dexec c "$PROFILE_PATH/bin/zsh" -lc "curl -sk -o /dev/null -w %{http_code} --max-time 5 -H 'Authorization: Bearer $tok' https://c-mitm.$PROXY_DOMAIN/flows || true")"
[ "$code" = 403 ] || [ "$code" = 000 ] || fail "restricted project reached the capture UI via Caddy: $code"

# Ingress: a request to c's public URL goes through mitmproxy, app sees the public Host.
"$E" exec -d nxt-c "$PROFILE_PATH/bin/caddy" respond --listen :8000 'host={http.request.host}'
sleep 2
body="$("$E" exec nxt-proxy "$PROFILE_PATH/bin/curl" -sk --max-time 10 \
  --resolve "c-8000.$PROXY_DOMAIN:443:127.0.0.1" "https://c-8000.$PROXY_DOMAIN/hello" || true)"
assert_eq "$body" "host=c-8000.$PROXY_DOMAIN" "ingress reaches the app with its public Host"
sleep 1
assert_contains "$(cat "$logf")" "ingress GET http://c-8000.$PROXY_DOMAIN/hello 200" "ingress recorded (the Caddy → app hop is plain http)"

# CLI views.
assert_contains "$(nx capture c log)" "example.com" "capture log"
nx capture c har "$NIXTEST_HOME/c.har" >/dev/null || fail "har export"
assert_contains "$(cat "$NIXTEST_HOME/c.har")" "example.com" "har contains the flow"

# Off: listeners removed live, the project goes direct again (no recreate).
egress_id="$("$E" inspect nxt-egress --format '{{.Id}}')"
nx capture c off >/dev/null || fail "capture off"
sleep 4
lines="$(wc -l < "$logf")"
code="$(dexec c "$PROFILE_PATH/bin/zsh" -lc 'curl -sk -o /dev/null -w %{http_code} https://example.com/ || true')"
case "$code" in 2*|3*) ;; *) fail "egress broken after capture off (got $code)";; esac
assert_eq "$(wc -l < "$logf")" "$lines" "nothing recorded after capture off"
# The UI port goes away → the egress container is recreated for that alone.
"$E" port nxt-egress | grep -q . && fail "UI still published with nothing captured"
[ "$("$E" inspect nxt-egress --format '{{.Id}}')" != "$egress_id" ] || note "egress kept (UI port unchanged)"

# Clear deletes the recordings.
nx capture c clear >/dev/null
[ -e "$logf" ] && fail "capture clear left the log"
true
