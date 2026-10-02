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
"$E" port nxt__proxy | grep -q "$port" || fail "relay port not published by proxy"
wait_tcp "$port" 25 || fail "ssh relay not reachable"
out="$(ssh "${ssh_opts[@]}" -p "$port" app@127.0.0.1 'echo RELAY-OK' 2>/dev/null)" || fail "ssh via relay"
assert_eq "$out" "RELAY-OK"

# proxy env exported in the container — squid lives in its own container
assert_contains "$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc 'echo $HTTPS_PROXY')" "nxt__egress:3128" "proxy env"
"$E" exec nxt__proxy sh -c 'ls /proc/*/exe -l 2>/dev/null' | grep -q squid && fail "squid still runs in the caddy container"
enets="$("$E" inspect nxt__egress --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
assert_contains "$enets" "nxt_p1_egress" "egress container on the project's internal net"
assert_contains "$enets" "$EGRESS_NET" "egress container on its own outbound net"
assert_not_contains "$nets" "$EGRESS_NET" "project NOT on the egress net"
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
egress_id="$("$E" inspect nxt__egress --format '{{.Id}}')"
nx allow p1 httpbin.org >/dev/null
assert_eq "$("$E" inspect nxt__egress --format '{{.Id}}')" "$egress_id" "egress NOT recreated by allow"

# Recreating the ingress proxy (every restricted 'run' does, for its relays)
# leaves the egress container — and so the network — alone.
nx proxy up >/dev/null || fail "proxy up"
assert_eq "$("$E" inspect nxt__egress --format '{{.Id}}')" "$egress_id" "egress NOT recreated by proxy up"
code="$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc \
  'curl -s -o /dev/null -w %{http_code} https://example.com/ || true')"
case "$code" in 2*|3*) ;; *) fail "egress broken after proxy up (got $code)";; esac

# The reordered config (`dstdomain -n`, name gates before the only dst
# rule) must parse under the REAL squid. A config it rejects would take out all
# egress, and the unit test can only check the text. The no-lookup property is
# covered by tests/squid_acl_sim.py in unit/08.
out="$("$E" exec nxt__egress "$PROFILE_PATH/bin/squid" -k parse -f /etc/egress/squid.conf 2>&1)" \
  || fail "squid rejected the generated config: $out"
printf '%s' "$out" | grep -qiE 'FATAL|unrecognized|Bungled' \
  && fail "squid complained about the generated config: $out"
# A look-alike of an allowed name is still refused.
denied="$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc \
  'curl -sv http://notexample.com/ -o /dev/null 2>&1 | grep -c 403 || true')"
[ "$denied" -ge 1 ] || fail "look-alike of an allowed host was not denied"

# egress log shows both outcomes; egress command summarises
log="$(cat "$PROXY_DIR/egress-data/egress.log")"
assert_contains "$log" "example.com" "allowed logged"
assert_contains "$log" "TCP_DENIED" "denial logged"
assert_contains "$(nx egress p1)" "example.com" "egress command output"
