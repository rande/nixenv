#!/usr/bin/env bash
# RUN-07: a broken startup hook never takes sshd down. Runs the generated
# entrypoint's hook/service section under /bin/sh (dash on debian-slim) with a
# fake runsv: sshd and the project services must start whatever the hooks do,
# and the outcome must land in ~/.nixenv-hooks.status.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$CONTEXT_DIR"; materialize_context
ep="$CONTEXT_DIR/entrypoint.sh"
SH="$(command -v dash || echo sh)"

# The tail of the entrypoint, from the status file to the final exec.
start_ln="$(grep -n '^HOOK_STATUS=' "$ep" | cut -d: -f1)"
[ -n "$start_ln" ] || fail "entrypoint defines HOOK_STATUS"
tail_part="$(tail -n +"$start_ln" "$ep")"
assert_contains "$tail_part" 'exec "$RUNSV" "$SVROOT/sshd"' "sshd's runsv is PID 1"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# run_case <name> <hook body> <expected status prefix>
run_case() {
  local c="$T/$1" i
  mkdir -p "$c/home/.nixenv-sv/sshd" "$c/home/.nixenv-sv/web" "$c/app/.nixenv" "$c/prof/etc"
  : > "$c/home/.nixenv-sv/sshd/run"; : > "$c/home/.nixenv-sv/web/run"
  printf '%s\n' "$2" > "$c/prof/etc/nixenv-hooks.sh"
  # fake runsv: records which service it was asked to supervise
  printf '#!/bin/sh\necho "$(basename "$1")" >> "%s/started"\n' "$c" > "$c/runsv"
  chmod +x "$c/runsv"
  { echo 'set -eu'
    echo "HOME_DIR='$c/home'; APP_MOUNT='$c/app'; NIXENV_EXTRA_PROFILE='$c/prof'"
    echo "SVROOT='$c/home/.nixenv-sv'; RUNSV='$c/runsv'; SSHD_PORT=2222; APP_USER=app"
    printf '%s\n' "$tail_part"
  } > "$c/ep.sh"
  "$SH" "$c/ep.sh" > "$c/out" 2>&1 || fail "$1: entrypoint exited non-zero: $(cat "$c/out")"
  for i in $(seq 1 50); do
    grep -qx web "$c/started" 2>/dev/null && break
    sleep 0.1
  done
  grep -qx sshd "$c/started" 2>/dev/null || fail "$1: sshd not started: $(cat "$c/out")"
  grep -qx web  "$c/started" 2>/dev/null || fail "$1: project service not started: $(cat "$c/out")"
  assert_contains "$(cat "$c/home/.nixenv-hooks.status")" "$3" "$1: status"
}

run_case ok        'nixenv_pre_ssh_start() { true; }' 'ok'
# The reported incident: a missing script at the top level of the flake hook.
run_case missing   '/nonexistent/setup.sh' 'failed: '
run_case fn-fails  'nixenv_pre_ssh_start() { false; }' 'failed: nixenv_pre_ssh_start'
run_case exits     'exit 5' 'failed: '
assert_contains "$(cat "$T/exits/home/.nixenv-hooks.status")" 'aborted (exit 5)' "exit is reported"
run_case set-e     'set -e; /nonexistent/setup.sh; echo unreachable' 'failed: '
assert_contains "$(cat "$T/exits/out")" 'WARNING startup hooks failed' "failure is logged"
exit 0
