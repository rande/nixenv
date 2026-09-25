#!/usr/bin/env bash
# Version reporting + licensing metadata. `--version` must work with no engine,
# no network and no writes — that is exactly what `brew test` runs.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# --- the variable exists and looks like a version -----------------------------
[ -n "${NIXENV_VERSION:-}" ] || fail "NIXENV_VERSION is unset"
case "$NIXENV_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "NIXENV_VERSION '$NIXENV_VERSION' is not x.y.z";;
esac

# --- `--version` and friends print it, and exit 0 -----------------------------
# Run the real script: this must hold for the installed binary, not just sourced.
for flag in --version -v version; do
  out="$(HOME=/nonexistent-nixenv-test "$REPO_DIR/nixenv.sh" "$flag" 2>/dev/null)" \
    || fail "'$flag' exited non-zero"
  assert_eq "$out" "nixenv $NIXENV_VERSION" "'$flag' prints the version"
done

# --- it must NOT touch the filesystem or need an engine -----------------------
# (a CONTEXT_DIR appearing here means it fell through to materialize_context)
ctx="$(mktemp -d)/ctx"
CONTEXT_DIR="$ctx" CONTAINER_ENGINE=/nonexistent-engine \
  "$REPO_DIR/nixenv.sh" --version >/dev/null 2>&1 || fail "--version needs an engine"
[ -e "$ctx" ] && fail "--version materialised the context (must be a pure read)"

# --- the version is dispatched BEFORE materialize_context ---------------------
body="$(cat "$REPO_DIR/nixenv.sh")"
ver_ln="$(printf '%s\n' "$body" | grep -n -- '-v|--version|version)' | cut -d: -f1)"
mat_ln="$(printf '%s\n' "$body" | grep -n '^  materialize_context$' | cut -d: -f1)"
[ "$ver_ln" -lt "$mat_ln" ] || fail "--version must be handled before materialize_context"

# --- usage advertises it, so it is discoverable -------------------------------
help="$("$REPO_DIR/nixenv.sh" --help)"
assert_contains "$help" "nixenv.sh $NIXENV_VERSION" "help header carries the version"
assert_contains "$help" "--version" "help lists the flag"

# --- GPLv3: the LICENSE is present and complete, and the script says so -------
lic="$REPO_DIR/LICENSE"
assert_file "$lic" "LICENSE exists"
lic_body="$(cat "$lic")"
for section in \
  "GNU GENERAL PUBLIC LICENSE" \
  "Version 3, 29 June 2007" \
  "TERMS AND CONDITIONS" \
  "END OF TERMS AND CONDITIONS" \
  "How to Apply These Terms"; do
  assert_contains "$lic_body" "$section" "LICENSE has '$section'"
done
# A truncated licence is worse than none — GPLv3 is ~35 kB.
[ "$(wc -c < "$lic")" -gt 30000 ] || fail "LICENSE looks truncated"

assert_contains "$body" "GNU General Public License v3.0" "script header states the licence"
assert_contains "$body" "NO WARRANTY" "script header carries the warranty disclaimer"

# --- a Homebrew-installed copy must refuse to self-install --------------------
assert_contains "$body" "installed via Homebrew" "cmd_install guards against brew prefixes"
assert_contains "$body" "/opt/homebrew/*" "guard covers the Apple-silicon prefix"
