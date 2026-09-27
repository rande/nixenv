#!/usr/bin/env bash
# write_egress_configs: squid ACLs (exact/subdomain/IP), relays, publishes,
# unrestricted exclusion, running-container guard, safety denies.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# Stub out everything engine-related.
ENGINE=docker
ensure_internal_net() { :; }
net_subnet()          { echo "172.30.9.0/24"; }
container_running()   { return 1; }

rm -rf "$PROJECTS_DIR" "$PROXY_DIR"
mkdir -p "$PROJECTS_DIR/alpha" "$PROJECTS_DIR/open"
printf 'gitlab.example.com\n.yarnpkg.com\n*.npmjs.org\n10.0.0.5\n# comment\n\n' > "$PROJECTS_DIR/alpha/allowed_hosts"
echo 23456 > "$PROJECTS_DIR/alpha/port"
printf '3000\n15432:5432\n' > "$PROJECTS_DIR/alpha/ports"
touch "$PROJECTS_DIR/open/unrestricted"           # opted out
echo 21111 > "$PROJECTS_DIR/open/port"

write_egress_configs
conf="$(cat "$PROXY_DIR/egress/squid.conf")"
startsh="$(cat "$PROXY_DIR/egress/start.sh")"

# projects
assert_contains "$EGRESS_PROJECTS" "alpha"
assert_not_contains "$EGRESS_PROJECTS" "open" "opted-out project excluded"

# ACL semantics: exact stays exact, dot/star become subdomain form, IP separate
# Names AND IPs share one `dstdomain -n` list (SEC-05): no `dst` ACL per project,
# because a `dst` ACL resolves the requested hostname — for denied names too.
assert_contains "$conf" "acl d_alpha dstdomain -n gitlab.example.com .yarnpkg.com .npmjs.org 10.0.0.5"
assert_not_contains "$conf" "acl i_alpha" "no per-project dst ACL"
assert_contains "$conf" "acl p_alpha src 172.30.9.0/24"
assert_contains "$conf" "acl nixenv_projects src 172.30.9.0/24" "all project subnets"
assert_contains "$conf" "http_access deny all" "default deny"
assert_contains "$conf" "http_access deny to_localnets" "no reach into private nets"
assert_contains "$conf" "http_port 0.0.0.0:$EGRESS_PORT" "explicit IPv4 bind"
assert_contains "$conf" "visible_hostname" "container-safe hostname"
assert_contains "$conf" "buffer-size=0KB" "unbuffered access log"
assert_not_contains "$conf" "pinger_enable" "no icmp directive"
assert_not_contains "$conf" "dns_v4_first" "no removed directives"

# relays + host-port publishes (ssh + declared ports)
assert_contains "$startsh" 'TCP-LISTEN:23456,fork,reuseaddr${RELAY_BIND:+,bind=$RELAY_BIND} TCP:nxt-alpha:2222' "ssh relay"
assert_contains "$startsh" 'TCP-LISTEN:3000,fork,reuseaddr${RELAY_BIND:+,bind=$RELAY_BIND} TCP:nxt-alpha:3000' "bare port relay"
assert_contains "$startsh" 'TCP-LISTEN:15432,fork,reuseaddr${RELAY_BIND:+,bind=$RELAY_BIND} TCP:nxt-alpha:5432' "mapped port relay"
assert_contains "$startsh" "rm -f /data/run/squid.pid" "stale pidfile cleared"
assert_contains "${EGRESS_PUB[*]}" "127.0.0.1:23456:23456"
sh -n "$PROXY_DIR/egress/start.sh" || fail "start.sh parses"

# guard: a running old-style container (own published ports) → relays skipped
container_running() { return 0; }
docker() { [ "$1" = port ] && echo "2222/tcp -> 127.0.0.1:23456"; return 0; }
ENGINE=docker
write_egress_configs
assert_not_contains "$(cat "$PROXY_DIR/egress/start.sh")" "TCP-LISTEN:23456" "relay skipped for running legacy container"

# in-place regeneration must keep the directory inode (bind-mount coherence)
ino1=$(ls -di "$PROXY_DIR/egress" | awk '{print $1}')
container_running() { return 1; }
write_egress_configs
ino2=$(ls -di "$PROXY_DIR/egress" | awk '{print $1}')
assert_eq "$ino2" "$ino1" "egress dir inode preserved"

# --- SEC-05: nothing may resolve a name before the name gate --------------------
# squid stops at the first matching http_access rule, and ANDs a rule's ACLs
# left to right. So the only `dst` rule (to_localnets, which resolves) must come
# AFTER every per-project name gate, or a denied name gets looked up — a DNS
# channel out of a restricted container even though the request is refused.
ln() { printf '%s\n' "$conf" | grep -n "^$1" | head -1 | cut -d: -f1; }
gate="$(ln 'http_access deny p_alpha !d_alpha')"
local_ln="$(ln 'http_access deny to_localnets')"
unknown="$(ln 'http_access deny !nixenv_projects')"
[ -n "$gate" ] && [ -n "$local_ln" ] && [ -n "$unknown" ] || fail "missing an ordering anchor"
[ "$unknown" -lt "$gate" ]     || fail "unknown sources must be denied before the name gates"
[ "$gate" -lt "$local_ln" ]    || fail "the name gate must precede 'deny to_localnets' (a dst ACL)"
# Every rule above to_localnets must be DNS-free: src, port, method, dstdomain -n.
printf '%s\n' "$conf" | awk -v stop="$local_ln" 'NR < stop && /^http_access/' \
  | grep -q 'to_localnets\|i_' && fail "a dst ACL is evaluated before the name gate"

# --- SEC-05, behaviourally: model squid's evaluation on THIS generated config ---
# tests/squid_acl_sim.py reports the verdict and whether squid would have to
# resolve a name to reach it.
SIM="$TESTS_DIR/squid_acl_sim.py"
cf="$PROXY_DIR/egress/squid.conf"
A=172.30.9.5
sim() { python3 "$SIM" "$cf" "$@"; }
assert_eq "$(sim $A GET secret-data.attacker.example 80)" "deny dns=no"  "denied name is not resolved"
assert_eq "$(sim $A GET evilnpmjs.org 80)"                "deny dns=no"  "suffix look-alike denied, not resolved"
assert_eq "$(sim 172.17.0.9 GET example.org 80)"          "deny dns=no"  "unknown source denied, not resolved"
assert_eq "$(sim $A CONNECT gitlab.example.com 8443)"     "deny dns=no"  "bad CONNECT port denied, not resolved"
assert_eq "$(sim $A CONNECT gitlab.example.com 443)"      "allow dns=yes" "allowed name works"
assert_eq "$(sim $A CONNECT registry.npmjs.org 443)"      "allow dns=yes" "allowed subdomain works"
assert_eq "$(sim $A CONNECT x.yarnpkg.com 443)"           "allow dns=yes" "*.foo entries allow subdomains"
# An allowed name that resolves to a private address is still refused: this
# lookup is legitimate, the NAME was allowed.
assert_eq "$(sim $A CONNECT gitlab.example.com 443 gitlab.example.com=10.1.2.3)" \
          "deny dns=yes" "allowed name rebinding to a private IP is refused"
# 10.0.0.5 is in the allowlist but private — to_localnets still wins, and an
# IP-literal request needs no lookup at all (-n: no reverse DNS).
assert_eq "$(sim $A GET 10.0.0.5 80)" "deny dns=no" "private IP stays blocked, no lookup"
