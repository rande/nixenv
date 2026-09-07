#!/usr/bin/env bash
# `stop` with no project stops every nixenv container (projects + proxy),
# leaves volumes intact, and never touches unrelated containers.
source "$(dirname "$0")/../lib.sh" it
sweep; trap 'sweep; "$E" rm -f nixenv-test-bystander >/dev/null 2>&1 || true' EXIT
require_store

mkproj a --unrestricted
mkproj b --unrestricted
nx run a >/dev/null
nx run b >/dev/null

# an unrelated container that must SURVIVE (name deliberately similar)
"$E" run -d --name nixenv-test-bystander debian:stable-slim sleep 300 >/dev/null

running() { "$E" ps --format '{{.Names}}' | grep -c "^$1\$" || true; }
[ "$(running nxt-a)" = 1 ] || fail "project a not running"
[ "$(running nxt-b)" = 1 ] || fail "project b not running"

nx stop >/dev/null || fail "stop (no args) failed"

[ "$(running nxt-a)" = 0 ] || fail "project a still running after stop"
[ "$(running nxt-b)" = 0 ] || fail "project b still running after stop"
[ "$(running nxt-proxy)" = 0 ] || fail "proxy still running after stop"
[ "$(running nixenv-test-bystander)" = 1 ] || fail "stop killed an unrelated container!"

# volumes must survive, and projects must restart cleanly
for v in nxt_a_app nxt_a_home nxt_a_databases; do
  "$E" volume inspect "$v" >/dev/null 2>&1 || fail "stop removed volume $v"
done
nx run a >/dev/null || fail "project won't restart after a global stop"

# stopping again is a harmless no-op
nx stop >/dev/null || fail "second stop should succeed"
out="$(nx stop 2>&1 || true)"
assert_contains "$out" "nothing to stop" "reports when there is nothing left"
