#!/usr/bin/env bash
# Volumes: created on run, seeded home, .keep markers, owned by our uid.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

mkproj p1 --unrestricted
nx run p1 >/dev/null

for v in nxt_p1_app nxt_p1_home nxt_p1_databases; do
  "$E" volume inspect "$v" >/dev/null 2>&1 || fail "volume missing: $v"
done

uid="$(id -u)"
assert_eq "$(involume nxt_p1_home     'stat -c %u /v')" "$uid" "home owned by uid"
assert_eq "$(involume nxt_p1_app      'stat -c %u /v')" "$uid" "app owned by uid"
assert_eq "$(involume nxt_p1_databases 'stat -c %u /v')" "$uid" "databases owned by uid"

involume nxt_p1_home 'test -f /v/.zshrc' || fail "home not seeded"
involume nxt_p1_app  'test -f /v/.keep'  || fail ".keep missing in empty app volume"
involume nxt_p1_databases 'test -f /v/.keep' || fail ".keep missing in databases"

# stop + run again must not clobber volume data
involume nxt_p1_databases 'touch /v/data.db' >/dev/null
nx stop p1 >/dev/null; nx run p1 >/dev/null
involume nxt_p1_databases 'test -f /v/data.db' || fail "databases lost on restart"
