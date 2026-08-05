#!/usr/bin/env bash
# Custom /etc/hosts: host command entries land in the container's /etc/hosts.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

mkproj p1 --unrestricted
nx host p1 db:10.9.9.9 api.local:127.0.0.1 >/dev/null
nx run p1 >/dev/null

hosts="$(dexec p1 cat /etc/hosts)"
assert_contains "$hosts" "10.9.9.9" "custom entry ip"
assert_contains "$hosts" "db" "custom entry name"
assert_contains "$hosts" "api.local"
assert_contains "$hosts" "127.0.1.1" "hostname line"
assert_contains "$hosts" "localhost" "base entries kept"

# restart keeps it idempotent (no duplicates)
nx stop p1 >/dev/null; nx run p1 >/dev/null
assert_eq "$(dexec p1 grep -c '10.9.9.9' /etc/hosts)" "1" "no duplicate on restart"
