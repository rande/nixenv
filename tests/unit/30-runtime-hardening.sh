#!/usr/bin/env bash
# Project and proxy containers drop all capabilities, forbid privilege
# gain through setuid binaries, and cap the number of processes.
source "$(dirname "$0")/../lib.sh"
source_nixenv

args="$(container_hardening_args | tr '\n' ' ')"
assert_contains "$args" "--cap-drop=ALL"                    "all capabilities dropped"
assert_contains "$args" "--security-opt=no-new-privileges"  "no privilege gain"
assert_contains "$args" "--pids-limit=4096"                 "default pids limit"
assert_contains "$(NIXENV_PIDS_LIMIT=512 container_hardening_args | tr '\n' ' ')" \
  "--pids-limit=512" "pids limit is configurable"
assert_not_contains "$(NIXENV_PIDS_LIMIT=0 container_hardening_args | tr '\n' ' ')" \
  "pids-limit" "NIXENV_PIDS_LIMIT=0 removes it"

body="$(cat "$REPO_DIR/nixenv.sh")"
run_fn="$(printf '%s' "$body" | sed -n '/^cmd_run()/,/^}/p' | code_only)"
assert_contains "$run_fn" 'harden=($(container_hardening_args))' "run computes the flags"
# BEFORE extra_args: a deliberate override in extra-parameters must still win.
h_ln="$(printf '%s\n' "$run_fn" | grep -n '"${harden\[@\]}"' | cut -d: -f1)"
x_ln="$(printf '%s\n' "$run_fn" | grep -n '"${extra_args\[@\]}"' | cut -d: -f1)"
[ -n "$h_ln" ] && [ -n "$x_ln" ] && [ "$h_ln" -lt "$x_ln" ] \
  || fail "hardening flags must come before extra_args ($h_ln/$x_ln)"
px_fn="$(printf '%s' "$body" | sed -n '/^cmd_proxy()/,/^}/p' | code_only)"
assert_contains "$px_fn" '$(container_hardening_args)' "the proxy is hardened too"
true
