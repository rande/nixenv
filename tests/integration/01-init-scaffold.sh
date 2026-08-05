#!/usr/bin/env bash
# init with an engine present: full scaffold incl. port + host ssh config.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT

mkproj p1
d="$NIXENV_PROJECTS_DIR/p1"
assert_file "$d/port"
port="$(cat "$d/port")"
[ "$port" -ge 20000 ] && [ "$port" -le 29999 ] || fail "ssh port out of range: $port"
assert_file "$d/ssh/config"
cfg="$(cat "$d/ssh/config")"
assert_contains "$cfg" "Host p1 p1.*"        "zmx host patterns"
assert_contains "$cfg" "Port $port"
assert_contains "$cfg" "zmx attach"
assert_file "$d/allowed_hosts"
assert_file "$d/home/.gitconfig.identity"
