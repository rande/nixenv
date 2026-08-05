#!/usr/bin/env bash
# expose publishes extra ports; delete removes container, volumes, network, dir.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

mkproj p1 --unrestricted
nx expose p1 18123 >/dev/null
nx run p1 >/dev/null
"$E" port nxt-p1 | grep -q 18123 || fail "exposed port not published"
assert_contains "$(cat "$NIXENV_PROJECTS_DIR/p1/ports")" "18123"

# restricted project delete must also remove the internal network
mkproj p2
nx run p2 >/dev/null
"$E" network inspect nxt_p2_egress >/dev/null 2>&1 || fail "internal net missing"

printf 'y\n' | nx delete p2 >/dev/null
"$E" ps -a --format '{{.Names}}' | grep -qx nxt-p2 && fail "container survived delete"
"$E" volume inspect nxt_p2_app >/dev/null 2>&1 && fail "app volume survived delete"
"$E" network inspect nxt_p2_egress >/dev/null 2>&1 && fail "internal net survived delete"
[ ! -d "$NIXENV_PROJECTS_DIR/p2" ] || fail "project dir survived delete"

# p1 untouched by p2's delete
"$E" volume inspect nxt_p1_app >/dev/null 2>&1 || fail "unrelated project volume removed"
