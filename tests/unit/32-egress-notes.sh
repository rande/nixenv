#!/usr/bin/env bash
# : `egress` points out allowlist entries that are wider than they look.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/p"
printf 'github.com\n.githubusercontent.com\nregistry.npmjs.org\n' > "$PROJECTS_DIR/p/allowed_hosts"
out="$(egress_allowlist_notes p)"
assert_contains "$out" "wildcards: .githubusercontent.com" "wildcard flagged"
assert_contains "$out" "forges: github.com .githubusercontent.com" "forges flagged"
assert_contains "$out" "push to ANY repo" "says why a forge matters"
assert_contains "$out" "port 22 is open to every allowed host" "missing ssh_hosts flagged"
assert_not_contains "$out" "registry.npmjs.org" "plain hosts not flagged"

printf 'github.com\n' > "$PROJECTS_DIR/p/ssh_hosts"
printf 'registry.npmjs.org\n' > "$PROJECTS_DIR/p/allowed_hosts"
assert_eq "$(egress_allowlist_notes p)" "" "nothing to say → silent"

grep -q '### What egress restriction does not protect against' "$REPO_DIR/README.md" \
  || fail "README must list the limits of the allowlist"
exports_path ssh_hosts || fail "ssh_hosts should travel with an export"
true
