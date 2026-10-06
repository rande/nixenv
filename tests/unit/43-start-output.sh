#!/usr/bin/env bash
# RUN-15: 'start' prints a short summary; -v keeps the full output.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# NIXENV_QUIET silences progress, never warnings.
assert_eq "$(NIXENV_QUIET=1 log hidden)" "" "quiet log"
assert_eq "$(NIXENV_QUIET=1 ok hidden)" "" "quiet ok"
assert_contains "$(NIXENV_QUIET=1 warn shown)" "shown" "warn always prints"
assert_contains "$(log shown)" "shown" "log prints by default"

# The summary.
ENGINE=docker
rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/alpha"
printf 'a.example\nb.example\n\n' > "$PROJECTS_DIR/alpha/allowed_hosts"
container_running() { [ "$1" = "$PROXY_NAME" ]; }
proxy_serves_dashboard() { return 0; }
PROXY_AUTOSTART=1
out="$(NIXENV_QUIET=1 run_summary alpha Started 1)"
assert_contains "$out" "Started '$(container_name alpha)'" "status line shown even when quiet"
assert_contains "$out" "ssh alpha" "how to get in"
assert_contains "$out" "https://alpha-<port>.$PROXY_DOMAIN/" "where it is served"
assert_contains "$out" "restricted, 2 host(s) allowed" "egress state, counted"
assert_contains "$out" "$(dashboard_project_url alpha)" "links the project's dashboard card"
assert_not_contains "$out" "a.example" "the allowlist itself is -v only"
assert_contains "$out" "start alpha -v" "points at the details"
[ "$(printf '%s\n' "$out" | wc -l)" -le 6 ] || fail "summary stays short: $out"
out="$(run_summary alpha Started 0)"
assert_not_contains "$out" "egress:" "unrestricted: no egress line"

# Wiring.
body="$(code_only < "$NIXENV_SH")"
run_fn="$(printf '%s\n' "$body" | sed -n '/^cmd_run()/,/^}/p')"
assert_contains "$run_fn" "-v|--verbose) verbose=1" "start accepts -v"
assert_contains "$run_fn" "local NIXENV_QUIET=1" "quiet unless -v"
assert_contains "$run_fn" 'run_summary "$name"' "short summary without -v"
px_fn="$(printf '%s\n' "$body" | sed -n '/^cmd_proxy()/,/^}/p')"
assert_contains "$px_fn" '[ "${NIXENV_QUIET:-0}" = 1 ] && return 0' "proxy up skips its info block when quiet"
assert_contains "$(usage)" "start <project> [-v]" "help documents -v"

# ssh/shell restore the terminal after the client returns (RUN-15).
for f in cmd_ssh cmd_shell; do
  fb="$(printf '%s\n' "$body" | sed -n "/^$f()/,/^}/p")"
  assert_contains "$fb" "terminal_reset" "$f resets the terminal afterwards"
  assert_contains "$fb" 'return "$rc"' "$f keeps the client's exit code"
done
assert_eq "$(terminal_reset </dev/null | wc -c | tr -d ' ')" 0 "no escape codes when not a TTY"
