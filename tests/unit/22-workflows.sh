#!/usr/bin/env bash
# The release workflow is the thing that turns a tag into something users
# install, so its guards are worth testing like any other code path.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rel="$REPO_DIR/.github/workflows/release.yml"
ci="$REPO_DIR/.github/workflows/ci.yml"
assert_file "$rel" "release workflow exists"
assert_file "$ci"  "ci workflow exists"

# --- both must be valid YAML with the shape Actions expects -------------------
python3 - "$rel" "$ci" <<'PY' || fail "workflow YAML is invalid"
import sys, yaml
for p in sys.argv[1:]:
    with open(p) as fh:
        d = yaml.safe_load(fh)
    assert isinstance(d, dict), f"{p}: not a mapping"
    # 'on' is parsed by YAML 1.1 as the boolean True — accept either spelling.
    trigger = d.get("on", d.get(True))
    assert trigger, f"{p}: no triggers"
    assert d.get("jobs"), f"{p}: no jobs"
    for name, job in d["jobs"].items():
        assert job.get("runs-on"), f"{p}: job {name} has no runs-on"
        assert job.get("steps"), f"{p}: job {name} has no steps"
PY

rel_body="$(cat "$rel")"

# --- it must fire on version tags, not on branches ---------------------------
python3 - "$rel" <<'PY' || fail "release must trigger only on vX.Y.Z tags"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get("on", d.get(True))
push = on.get("push", {})
assert "tags" in push, "no tag trigger"
assert "branches" not in push, "release must not fire on branch pushes"
assert any("[0-9]" in t for t in push["tags"]), f"tag filter too loose: {push['tags']}"
PY

# --- the tag/NIXENV_VERSION guard must exist and gate everything else --------
# Without it a mistyped tag ships a formula whose `brew test` fails for users.
assert_contains "$rel_body" 'NIXENV_VERSION' "checks the declared version"
assert_contains "$rel_body" 'GITHUB_REF_NAME#v' "derives the version from the tag"
python3 - "$rel" <<'PY' || fail "release/formula jobs must depend on verify"
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
assert "verify" in jobs, "no verify job"
def needs(j):
    n = jobs[j].get("needs", [])
    return [n] if isinstance(n, str) else n
assert "verify" in needs("release"), "release must need verify"
# formula -> release -> verify keeps the ordering transitive
assert "release" in needs("formula"), "formula must need release"
PY

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
ci_body="$(cat "$ci")"
assert_contains "$ci_body" 'macos-latest' "CI covers macOS (Bash 3.2)"
assert_contains "$ci_body" './tests/run.sh unit' "CI runs the unit suite"
