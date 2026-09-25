#!/usr/bin/env bash
# The Homebrew formula must stay in step with the script it packages. A formula
# that drifts fails on users' machines, never on ours — so check it here.
source "$(dirname "$0")/../lib.sh"
source_nixenv

f="$REPO_DIR/packaging/homebrew/Formula/nixenv.rb"
assert_file "$f" "formula exists"
body="$(cat "$f")"

# --- the packaged version must equal the script's -----------------------------
url="$(sed -n 's/^  url "\(.*\)"$/\1/p' "$f")"
[ -n "$url" ] || fail "formula has no url"
tag="$(printf '%s' "$url" | sed -n 's|.*/tags/v\([0-9][0-9.]*\)\.tar\.gz$|\1|p')"
[ -n "$tag" ] || fail "url does not point at a vX.Y.Z tag tarball: $url"
assert_eq "$tag" "$NIXENV_VERSION" "formula url tag matches NIXENV_VERSION"

# --- sha256 must at least be well-formed (update-formula.sh fills the real one)
sha="$(sed -n 's/^  sha256 "\(.*\)"$/\1/p' "$f")"
case "$sha" in
  [0-9a-f]*) [ "${#sha}" -eq 64 ] || fail "sha256 is ${#sha} chars, expected 64";;
  *) fail "sha256 is not lowercase hex: $sha";;
esac

# --- the binary must land on PATH under the right name ------------------------
assert_contains "$body" 'bin.install "nixenv.sh" => "nixenv"' "installs as 'nixenv'"

# --- licence must match what the repo actually ships --------------------------
assert_contains "$body" 'license "GPL-3.0-or-later"' "declares GPL-3.0-or-later"

# --- the test block must assert the version round-trips -----------------------
# (this is the check that catches a stale formula on the user's machine)
assert_contains "$body" 'assert_match "nixenv #{version}"' "test asserts --version"

# --- no dependency on bash: the script must keep the Bash 3.2 line ------------
# If someone adds `depends_on "bash"` they must also change the shebang, so make
# the coupling explicit rather than letting the formula quietly grow a dep.
if printf '%s' "$body" | grep -q 'depends_on "bash"'; then
  fail "formula depends on bash — then nixenv.sh's shebang must change too"
fi

# --- templates shipped by the formula must all exist in the repo --------------
assert_contains "$body" 'pkgshare.install "templates"' "ships templates"
for t in $(printf '%s' "$body" | grep -o 'templates/[a-z0-9-]*\.nix' | sort -u); do
  assert_file "$REPO_DIR/$t" "formula references an existing $t"
done

# --- the release helper must be present and executable ------------------------
u="$REPO_DIR/packaging/homebrew/update-formula.sh"
assert_file "$u" "update-formula.sh exists"
[ -x "$u" ] || fail "update-formula.sh is not executable"
bash -n "$u" || fail "update-formula.sh has a syntax error"
# It must refuse a version that disagrees with the script, WITHOUT any network.
out="$(bash "$u" 999.999.999 2>&1 || true)"
assert_contains "$out" "NIXENV_VERSION" "refuses a mismatched version"
assert_not_contains "$out" "fetching" "bails before downloading anything"
