#!/usr/bin/env bash
# cmd_init without an engine: scaffolds host files, seeds forge domain,
# validates --app-path, restricted by default / --unrestricted opt-out.
source "$(dirname "$0")/../lib.sh"

# Force the no-engine path so this test is deterministic on machines WITH docker
# (otherwise init would attempt volume creation / a real clone).
export CONTAINER_ENGINE=nixenv-test-no-engine

rm -rf "$NIXENV_PROJECTS_DIR"

# init with a git URL: engine is missing, so clone is skipped — but all host-side
# state must exist. (clone_repo requires an engine → expect non-zero exit; the
# scaffold happens first.)
nx init alpha https://gitlab.example.com/team/app.git </dev/null >/dev/null 2>&1 || true
assert_file "$NIXENV_PROJECTS_DIR/alpha/allowed_hosts"
assert_contains "$(cat "$NIXENV_PROJECTS_DIR/alpha/allowed_hosts")" "gitlab.example.com" "forge seeded"
assert_file "$NIXENV_PROJECTS_DIR/alpha/home/.zshrc"
assert_file "$NIXENV_PROJECTS_DIR/alpha/home/.gitconfig.identity"
assert_contains "$(cat "$NIXENV_PROJECTS_DIR/alpha/home/.gitconfig.identity")" "test@nixenv.local"
assert_no_file "$NIXENV_PROJECTS_DIR/alpha/unrestricted" "restricted by default"

# opt-out at init
nx init beta --unrestricted </dev/null >/dev/null 2>&1 || true
assert_file "$NIXENV_PROJECTS_DIR/beta/unrestricted"

# app-path stored + validated
nx init gamma --app-path=/srv/code </dev/null >/dev/null 2>&1 || true
assert_eq "$(cat "$NIXENV_PROJECTS_DIR/gamma/app_mount")" "/srv/code"
if nx init bad1 --app-path=relative </dev/null >/dev/null 2>&1; then fail "relative app-path accepted"; fi
if nx init bad2 --app-path=/nix    </dev/null >/dev/null 2>&1; then fail "reserved app-path accepted"; fi
if nx init proxy </dev/null >/dev/null 2>&1; then fail "reserved name 'proxy' accepted"; fi

# init REFUSES to touch an existing project (guards against typo'd names)
nx init alpha </dev/null >/dev/null 2>&1 && fail "init on an existing project must fail"
out="$(nx init alpha </dev/null 2>&1 || true)"
assert_contains "$out" "already exists"  "explains why it refused"
assert_contains "$out" "--force"         "offers the escape hatch"
assert_contains "$out" "delete alpha"    "offers removal"

# …and refuses BEFORE doing anything (no template fetch, no prompt)
if nx init alpha --template=https://127.0.0.1:9/nope.nix </dev/null >/dev/null 2>&1; then
  fail "existence check must precede template resolution"
fi

# --force re-scaffolds without clobbering existing files
echo CUSTOM > "$NIXENV_PROJECTS_DIR/alpha/home/.zshrc"
nx init alpha --force </dev/null >/dev/null 2>&1 || true
assert_eq "$(cat "$NIXENV_PROJECTS_DIR/alpha/home/.zshrc")" "CUSTOM" "no clobber on --force re-init"

# a brand-new name still works
nx init zeta </dev/null >/dev/null 2>&1 || fail "init of a new project must succeed"
assert_file "$NIXENV_PROJECTS_DIR/zeta/home/.zshrc"

# init WITHOUT --build must exit 0 (regression: trailing `[ ] && cmd` made the
# function return 1 under set -e)
nx init delta </dev/null >/dev/null 2>&1 || fail "init without --build must exit 0"

# --allow= seeds the egress allowlist at creation (comma-separated + repeatable,
# normalised like the 'allow' command), alongside the forge domain.
nx init eps https://gitlab.example.com/t/a.git \
   --allow=registry.npmjs.org,'*.yarnpkg.com' --allow=pypi.org </dev/null >/dev/null 2>&1 || true
ah="$(cat "$NIXENV_PROJECTS_DIR/eps/allowed_hosts")"
assert_contains "$ah" "gitlab.example.com" "forge still seeded"
assert_contains "$ah" "registry.npmjs.org" "comma-separated entry"
assert_contains "$ah" ".yarnpkg.com"       "*.foo normalised to .foo"
assert_contains "$ah" "pypi.org"           "repeated --allow"
if nx init bad3 --allow='https://x.com' </dev/null >/dev/null 2>&1; then fail "invalid --allow accepted"; fi
