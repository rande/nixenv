#!/usr/bin/env bash
# EGR-06: starting a restricted project hot-reloads a proxy whose creation-time
# config (relays, published ports, cert) is unchanged, recreating it otherwise.
source "$(dirname "$0")/../lib.sh"
source_nixenv

ENGINE=docker
ensure_internal_net() { :; }
net_subnet()          { echo "172.30.9.0/24"; }
container_running()   { return 1; }   # inside write_egress_configs: no running project

rm -rf "$PROJECTS_DIR" "$PROXY_DIR"
mkdir -p "$PROJECTS_DIR/alpha"
echo 23456 > "$PROJECTS_DIR/alpha/port"

# --- proxy_start_sum follows what is fixed at creation -----------------------
write_egress_configs >/dev/null 2>&1
s0="$(proxy_start_sum 1)"
[ -n "$s0" ] || fail "checksum computed"
write_egress_configs >/dev/null 2>&1
assert_eq "$(proxy_start_sum 1)" "$s0" "same projects → same checksum"
[ "$(proxy_start_sum 0)" != "$s0" ] || fail "cert mount change → new checksum"
printf '3000\n' > "$PROJECTS_DIR/alpha/ports"
write_egress_configs >/dev/null 2>&1
s1="$(proxy_start_sum 1)"
[ "$s1" != "$s0" ] || fail "a new relayed port → new checksum"

# --- proxy_refresh_for_run picks reload vs up --------------------------------
mkdir -p "$PROXY_DIR/certs"; : > "$PROXY_DIR/certs/wildcard.pem"
# cmd_proxy runs in a subshell: record its calls in a file.
log_f="$PROXY_DIR/calls"
cmd_proxy() { printf ' %s' "$1" >> "$log_f"; }
refresh() { : > "$log_f"; proxy_refresh_for_run >/dev/null 2>&1; called="$(cat "$log_f")"; }
proxy_serves_dashboard() { return 0; }
container_running() { [ "$1" = "$PROXY_NAME" ]; }
label="$s1"
docker() { [ "$1" = inspect ] && printf '%s\n' "$label"; }

refresh
assert_eq "$called" " reload" "matching label → hot reload, no recreate"

label="stale"; refresh
assert_eq "$called" " up" "changed relays → recreate"

label="$s1"; proxy_serves_dashboard() { return 1; }
refresh
assert_eq "$called" " up" "proxy without the dashboard mount → recreate"
proxy_serves_dashboard() { return 0; }

cmd_proxy() { printf ' %s' "$1" >> "$log_f"; [ "$1" != reload ]; }
refresh
assert_eq "$called" " reload up" "failed reload → recreate"

# A capture change seen by the pre-check pass survives the second pass.
CAPTURE_PENDING=1 write_egress_configs >/dev/null 2>&1
assert_eq "$CAPTURE_CHANGED" 1 "CAPTURE_PENDING carries into the next pass"
write_egress_configs >/dev/null 2>&1
assert_eq "$CAPTURE_CHANGED" 0 "unchanged capture.conf → no restart"

# --- wiring --------------------------------------------------------------------
body="$(code_only < "$NIXENV_SH")"
run_fn="$(printf '%s\n' "$body" | sed -n '/^cmd_run()/,/^}/p')"
assert_contains "$run_fn" "proxy_refresh_for_run" "restricted start refreshes through proxy_refresh_for_run"
assert_contains "$body" '--label "$PROXY_SUM_LABEL=$(proxy_start_sum "$cert")"' "proxy is labelled at creation"
assert_contains "$body" 'start|run) cmd_run' "start is the command, run its alias"
assert_contains "$(usage)" "start <project>" "help names start"
