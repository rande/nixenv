#!/usr/bin/env bash
# `build <project> --dir=<path>` is remembered in <project>/flake_dir, so a
# project whose flake lives outside the repo root rebuilds with a bare
# `build <project>`. Forgetting the flag silently builds the wrong flake.
source "$(dirname "$0")/../lib.sh"
source_nixenv

body="$(cat "$REPO_DIR/nixenv.sh")"
bp="$(printf '%s' "$body" | sed -n '/^cmd_build_project()/,/^}/p')"

assert_contains "$bp" 'flake_dir'   "stores the dir"
assert_contains "$bp" 'dir_given'   "distinguishes 'not passed' from 'passed empty'"
assert_contains "$bp" 'cleared the remembered flake dir' "--dir= clears it"

# The remembered value must be READ before the build uses $dir, and only when
# the flag was absent — otherwise an explicit --dir could not override it.
printf '%s' "$bp" | code_only | grep -q 'elif \[ -f "$dirfile" \]' \
  || fail "the remembered dir must be an elif on dir_given, or it cannot be overridden"

# It is per-project and machine-independent, so it belongs in an export.
exports_path flake_dir || fail "flake_dir should travel with an export (a rebuild there needs it too)"

# --- behaviour, with the engine stubbed out ----------------------------------
rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/demo"
ENGINE=true
require_engine()     { :; }
volume_exists()      { return 0; }
store_is_populated() { return 0; }
# Stop the moment the dir decision is made; echo what the build would use.
ensure_volumes()     { printf 'DIR=[%s]\n' "${dir:-}"; exit 0; }

run_build() { ( cmd_build_project demo "$@" ) 2>&1; }

out="$(run_build --dir=infra/nixos)"
assert_eq "$(cat "$PROJECTS_DIR/demo/flake_dir")" "infra/nixos" "explicit --dir is stored"

out="$(run_build)"
assert_contains "$out" "using remembered flake dir: --dir=infra/nixos" "reused without the flag"

out="$(run_build --dir=other)"
assert_eq "$(cat "$PROJECTS_DIR/demo/flake_dir")" "other" "a new --dir overrides the stored one"
assert_not_contains "$out" "using remembered" "an explicit flag does not announce the old value"

out="$(run_build --dir=)"
[ -f "$PROJECTS_DIR/demo/flake_dir" ] && fail "--dir= did not clear the stored value"
assert_contains "$out" "cleared the remembered flake dir" "clearing says so"

out="$(run_build)"
assert_not_contains "$out" "using remembered" "after clearing, back to the repo root"

# A project that never used --dir must not grow the file.
mkdir -p "$PROJECTS_DIR/plain"
( cmd_build_project plain ) >/dev/null 2>&1
[ -f "$PROJECTS_DIR/plain/flake_dir" ] && fail "a plain build should not create flake_dir"
true
