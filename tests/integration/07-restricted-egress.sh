#!/usr/bin/env bash
# Egress restriction end-to-end: internal net, no published ports, ssh relay,
# squid default-deny, allow hot-reload, egress log. Needs internet access.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
require_store_bin squid
require_store_bin socat
command -v ssh >/dev/null 2>&1 || skip "ssh client not installed"

mkproj p1                          # restricted by default
nx allow p1 example.com >/dev/null # will be our "validated" host
nx run p1 >/dev/null               # starts project + refreshes proxy (relays/ACL)

# network isolation
nets="$("$E" inspect nxt-p1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
assert_contains "$nets" "nxt_p1_egress" "on internal network"
"$E" port nxt-p1 | grep -q . && fail "restricted project must publish no ports"

# ssh works through the proxy relay
port="$(cat "$NIXENV_PROJECTS_DIR/p1/port")"
"$E" port nxt-proxy | grep -q "$port" || fail "relay port not published by proxy"
wait_tcp "$port" 25 || fail "ssh relay not reachable"
out="$(ssh "${ssh_opts[@]}" -p "$port" app@127.0.0.1 'echo RELAY-OK' 2>/dev/null)" || fail "ssh via relay"
assert_eq "$out" "RELAY-OK"

# proxy env exported in the container
assert_contains "$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc 'echo $HTTPS_PROXY')" ":3128" "proxy env"
# ssh egress tunnel configured
assert_contains "$(dexec p1 cat /home/app/.ssh/config)" "nixenv-egress" "ProxyCommand block"

# default-deny vs validated host (through squid, from inside)
denied="$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc \
  'curl -sv https://google.com/ -o /dev/null 2>&1 | grep -c 403 || true')"
[ "$denied" -ge 1 ] || fail "unvalidated host was not denied"
code="$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc \
  'curl -s -o /dev/null -w %{http_code} https://example.com/ || true')"
case "$code" in 2*|3*) ;; *) fail "validated host not reachable (got $code)";; esac

# hot-reload: newly allowed host works without recreating the proxy
proxy_id="$("$E" inspect nxt-proxy --format '{{.Id}}')"
nx allow p1 httpbin.org >/dev/null
assert_eq "$("$E" inspect nxt-proxy --format '{{.Id}}')" "$proxy_id" "proxy NOT recreated by allow"

# egress log shows both outcomes; egress command summarises
log="$(cat "$PROXY_DIR/data/egress.log")"
assert_contains "$log" "example.com" "allowed logged"
assert_contains "$log" "TCP_DENIED" "denial logged"
assert_contains "$(nx egress p1)" "example.com" "egress command output"
