#!/usr/bin/env bash
# The release workflow is the thing that turns a tag into something users
# install, so its guards are worth testing like any other code path.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rel="$REPO_DIR/.github/workflows/release.yml"
ci="$REPO_DIR/.github/workflows/ci.yml"
assert_file "$rel" "release workflow exists"
assert_file "$ci"  "ci workflow exists"

rel_body="$(cat "$rel")"
ci_body="$(cat "$ci")"

# --- structure, without needing a YAML library --------------------------------
# PyYAML is NOT guaranteed: GitHub's macOS runner ships a python3 with no yaml
# module, which used to fail this whole file. GitHub itself rejects malformed
# workflow YAML on push, so a local parse is a bonus, not the point — the
# invariants below are what actually matter, and they are checked textually.
# `needs:` is asserted in its scalar form (`needs: verify`), which is what these
# files use; a list form would need the parser and is deliberately not allowed.
job_needs() { # job_needs <file> <job> -> prints the dependency, if any
  awk '
    /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { job = $1; sub(":", "", job); next }
    job == j && $1 == "needs:"          { print $2; exit }
  ' j="$2" "$1"
}
job_exists() { grep -qE "^  $2:[[:space:]]*$" "$1"; }

for wf in "$rel" "$ci"; do
  n="$(basename "$wf")"
  grep -qE '^name:' "$wf"     || fail "$n: no name"
  grep -qE '^jobs:' "$wf"     || fail "$n: no jobs"
  grep -qE '^[[:space:]]+runs-on:' "$wf" || fail "$n: no runs-on"
  grep -qE '^[[:space:]]+steps:'   "$wf" || fail "$n: no steps"
  # Tabs are invalid YAML indentation and easy to introduce by accident.
  printf '%s' "$(cat "$wf")" | grep -qP '^\t' 2>/dev/null \
    && fail "$n: leading tab (invalid YAML indentation)"
done

# Bonus: a real parse when a YAML library happens to be available.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$rel" "$ci" <<'PY' || fail "workflow YAML is invalid"
import sys, yaml
for p in sys.argv[1:]:
    d = yaml.safe_load(open(p))
    assert isinstance(d, dict), f"{p}: not a mapping"
    # 'on' is parsed by YAML 1.1 as the boolean True — accept either spelling.
    assert d.get("on", d.get(True)), f"{p}: no triggers"
    for name, job in d["jobs"].items():
        assert job.get("runs-on"), f"{p}: job {name} has no runs-on"
        assert job.get("steps"), f"{p}: job {name} has no steps"
PY
else
  echo "note: PyYAML unavailable — structural checks are text-only here"
fi

# --- it must fire on version tags, not on branches ---------------------------
assert_contains "$rel_body" 'tags:' "release has a tag trigger"
assert_contains "$rel_body" '[0-9]' "tag filter is version-shaped, not 'v*'"
if grep -qE '^[[:space:]]+branches:' "$rel"; then
  fail "release must not fire on branch pushes"
fi

# --- the tag/NIXENV_VERSION guard must exist and gate everything else --------
# Without it a mistyped tag ships a formula whose `brew test` fails for users.
assert_contains "$rel_body" 'NIXENV_VERSION' "checks the declared version"
assert_contains "$rel_body" 'GITHUB_REF_NAME#v' "derives the version from the tag"
# The dependency chain is what makes the guard binding: without it, `release`
# would publish even when `verify` failed. formula → release → verify keeps the
# ordering transitive.
for j in verify release formula; do
  job_exists "$rel" "$j" || fail "release workflow has no '$j' job"
done
assert_eq "$(job_needs "$rel" release)" "verify"  "release depends on verify"
assert_eq "$(job_needs "$rel" formula)" "release" "formula depends on release"

# --- the suite must actually run in the pipeline ------------------------------
assert_contains "$rel_body" './tests/run.sh unit' "release runs the unit suite"

# --- the tap update must reuse update-formula.sh, not reimplement the sha -----
assert_contains "$rel_body" 'packaging/homebrew/update-formula.sh' "reuses the release helper"
if printf '%s' "$rel_body" | grep -qE 'sha256sum|shasum -a 256'; then
  fail "workflow computes a sha itself — use update-formula.sh (one implementation)"
fi

# --- a missing tap token must skip, never fail the release -------------------
assert_contains "$rel_body" 'TAP_TOKEN' "gates on a tap token"
assert_contains "$rel_body" '::notice::' "skips with a notice when unset"

# --- write scope is needed to create a release, and only that ----------------
assert_contains "$rel_body" 'contents: write' "declares the permission it needs"

# --- no action may pin a runtime GitHub has deprecated ------------------------
# actions/checkout@v4 and older declare `using: node20`; runners force them onto
# node24 and emit a deprecation warning on every run. Keep them at v5+.
for wf in "$rel" "$ci"; do
  if grep -qE 'actions/checkout@v[1-4]([^0-9]|$)' "$wf"; then
    fail "$(basename "$wf"): actions/checkout must be v5 or newer (v4 = deprecated node20)"
  fi
  grep -q 'actions/checkout@v' "$wf" || fail "$(basename "$wf"): no checkout step"
done

# --- CI must cover macOS, where Bash 3.2 lives -------------------------------
assert_contains "$ci_body" 'macos-latest' "CI covers macOS (Bash 3.2)"
assert_contains "$ci_body" './tests/run.sh unit' "CI runs the unit suite"
