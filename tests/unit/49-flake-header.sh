#!/usr/bin/env bash
# TOOL-10: `build <project>` offers the `# nixenv:` header of the project's
# flake (allow, app-path), and applies it only after an interactive yes.
source "$(dirname "$0")/../lib.sh"
source_nixenv

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/demo"
P="$PROJECTS_DIR/demo"
touch "$P/unrestricted"            # cmd_allow then saves without touching an engine
printf 'github.com\n' > "$P/allowed_hosts"
resolve_engine() { return 1; }
ANSWER=no; TTY=1
confirm_tty()  { [ "$TTY" = 1 ] && [ "$ANSWER" = yes ]; }
stdin_is_tty() { [ "$TTY" = 1 ]; }

cat > "$T/flake.nix" <<'NIX'
# nixenv:description  Billing API
# nixenv:allow        github.com registry.npmjs.org *.stripe.com https://evil.example/x
# nixenv:app-path     /srv/billing
# nixenv:port         3000
{ outputs = _: { }; }
NIX
offer() { ( apply_flake_header demo "$T/flake.nix" ) 2>&1; }

# Not a terminal: shown, nothing applied, nothing remembered.
TTY=0; out="$(offer)"
assert_contains "$out" "allow registry.npmjs.org .stripe.com" "offers only the missing hosts, normalised"
assert_not_contains "$out" "allow github.com" "an already allowed host is not offered"
assert_contains "$out" "ignoring invalid allow entry 'https://evil.example/x'" "an invalid host is dropped"
assert_contains "$out" "app-path: /app → /srv/billing" "offers the app-path"
assert_contains "$out" "port 3000" "shows the port"
assert_contains "$out" "no terminal to confirm" "says why nothing was applied"
assert_eq "$(cat "$P/allowed_hosts")" "github.com" "no TTY: allowlist untouched"
assert_no_file "$P/app_mount" "no TTY: app-path untouched"
assert_no_file "$P/.flake-header-declined" "no TTY: no decision recorded"

# Interactive no: remembered for this exact set, then only logged.
TTY=1; ANSWER=no; offer >/dev/null
assert_eq "$(cat "$P/allowed_hosts")" "github.com" "a no applies nothing"
[ -s "$P/.flake-header-declined" ] || fail "an interactive no is remembered"
out="$(offer)"
assert_contains "$out" "declined earlier" "the same set is not asked again"
assert_not_contains "$out" "Apply them" "no prompt for a declined set"

# A different set is asked again; yes applies it.
sed -i.bak 's/registry.npmjs.org/registry.yarnpkg.com/' "$T/flake.nix"
ANSWER=yes; out="$(offer)"
assert_contains "$out" "registry.yarnpkg.com" "a changed set is offered again"
assert_eq "$(sort "$P/allowed_hosts" | tr '\n' ' ')" ".stripe.com github.com registry.yarnpkg.com " "yes adds the hosts"
assert_eq "$(cat "$P/app_mount")" "/srv/billing" "yes sets the app-path"
assert_no_file "$P/.flake-header-declined" "yes clears the remembered no"

# Nothing new: silent. An explicit app_mount is never challenged.
sed -i.bak 's| https://evil.example/x||' "$T/flake.nix"
assert_eq "$(offer)" "" "nothing to offer, nothing printed"
printf '/var/www' > "$P/app_mount"; assert_eq "$(offer)" "" "an existing app_mount is kept"

# No header at all, or a missing file: nothing happens.
printf '{ outputs = _: { }; }\n' > "$T/plain.nix"
assert_eq "$( ( apply_flake_header demo "$T/plain.nix" ) 2>&1)" "" "no header"
assert_eq "$( ( apply_flake_header demo "$T/none.nix" ) 2>&1)" "" "no flake"

# Wired into the project build, after extraction and before the builder runs.
bp="$(sed -n '/^cmd_build_project()/,/^}/p' "$NIXENV_SH" | code_only)"
h="$(printf '%s\n' "$bp" | grep -n 'apply_flake_header "$name" "$fdir/flake.nix"' | cut -d: -f1)"
b="$(printf '%s\n' "$bp" | grep -n 'run_builder project' | cut -d: -f1)"
[ -n "$h" ] && [ "$h" -lt "$b" ] || fail "build offers the header before building"
true
