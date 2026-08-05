#!/usr/bin/env bash
# Unrestricted run: container up, ssh port published + open passwordless login.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
command -v ssh >/dev/null 2>&1 || skip "ssh client not installed"

mkproj p1 --unrestricted
nx run p1 >/dev/null
"$E" ps --format '{{.Names}}' | grep -qx nxt-p1 || fail "container not running"
"$E" port nxt-p1 | grep -q . || fail "no published ports on unrestricted project"

port="$(cat "$NIXENV_PROJECTS_DIR/p1/port")"
wait_tcp "$port" 20 || fail "sshd not reachable on 127.0.0.1:$port"
out="$(ssh "${ssh_opts[@]}" -p "$port" app@127.0.0.1 'echo OK-$USER' 2>/dev/null)" \
  || fail "open ssh login failed"
assert_eq "$out" "OK-app"

# environment inside a login shell: profile on PATH, project name set
out="$(ssh "${ssh_opts[@]}" -p "$port" app@127.0.0.1 'echo $NIXENV_PROJECT; command -v git' 2>/dev/null)"
assert_contains "$out" "p1" "NIXENV_PROJECT exported"
assert_contains "$out" "/nix/var/nix/profiles" "store git on PATH"
