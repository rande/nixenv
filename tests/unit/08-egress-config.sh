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
assert_contains "$conf" "acl d_alpha dstdomain gitlab.example.com .yarnpkg.com .npmjs.org"
assert_contains "$conf" "acl i_alpha dst 10.0.0.5"
assert_contains "$conf" "acl p_alpha src 172.30.9.0/24"
assert_contains "$conf" "http_access deny all" "default deny"
assert_contains "$conf" "http_access deny to_localnets" "no reach into private nets"
assert_contains "$conf" "http_port 0.0.0.0:$EGRESS_PORT" "explicit IPv4 bind"
assert_contains "$conf" "visible_hostname" "container-safe hostname"
assert_contains "$conf" "buffer-size=0KB" "unbuffered access log"
assert_not_contains "$conf" "pinger_enable" "no icmp directive"
assert_not_contains "$conf" "dns_v4_first" "no removed directives"

# relays + host-port publishes (ssh + declared ports)
assert_contains "$startsh" "TCP-LISTEN:23456,fork,reuseaddr TCP:nxt-alpha:2222" "ssh relay"
assert_contains "$startsh" "TCP-LISTEN:3000,fork,reuseaddr TCP:nxt-alpha:3000" "bare port relay"
assert_contains "$startsh" "TCP-LISTEN:15432,fork,reuseaddr TCP:nxt-alpha:5432" "mapped port relay"
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
