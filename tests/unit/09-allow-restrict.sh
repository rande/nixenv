#!/usr/bin/env bash
# allow/restrict via the CLI: dedupe, normalisation, validation, default-on.
source "$(dirname "$0")/../lib.sh"

rm -rf "$NIXENV_PROJECTS_DIR"; mkdir -p "$NIXENV_PROJECTS_DIR/p/home"   # minimal scaffold

# allow: appends, dedupes, normalises *. → .
nx allow p registry.npmjs.org >/dev/null
nx allow p registry.npmjs.org >/dev/null       # dup
nx allow p '*.yarnpkg.com' >/dev/null
ah="$(cat "$NIXENV_PROJECTS_DIR/p/allowed_hosts")"
assert_eq "$(grep -c 'registry.npmjs.org' <<<"$ah")" "1" "deduped"
assert_contains "$ah" ".yarnpkg.com" "star normalised to dot"

# invalid entries rejected
if nx allow p 'https://foo.com' >/dev/null 2>&1; then fail "scheme should be rejected"; fi
if nx allow p 'foo.com:443'     >/dev/null 2>&1; then fail "port should be rejected"; fi

# restricted by default; off writes marker; on removes it
source_nixenv
is_restricted p || fail "default must be restricted"
nx restrict p off >/dev/null 2>&1 || true      # (no engine → still writes marker)
assert_file "$NIXENV_PROJECTS_DIR/p/unrestricted"
nx restrict p on  >/dev/null 2>&1 || true
assert_no_file "$NIXENV_PROJECTS_DIR/p/unrestricted"

# host command: name:ip conversion + IP validation
nx host p db:10.0.0.5 >/dev/null 2>&1 || true
assert_contains "$(cat "$NIXENV_PROJECTS_DIR/p/hosts.extra")" "10.0.0.5	db"
if nx host p gw:host-gateway >/dev/null 2>&1; then fail "non-IP should be rejected"; fi
