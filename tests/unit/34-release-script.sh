#!/usr/bin/env bash
# release.sh, end to end but offline: a local bare repo stands in for GitHub,
# another for the Homebrew tap, and fake `gh`/`curl` on PATH stand in for the
# API. The real update-formula.sh runs against a tarball of the tagged commit.
source "$(dirname "$0")/../lib.sh"
command -v git >/dev/null 2>&1 || skip "git not installed"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
git config --global init.defaultBranch main

# --- a minimal copy of the repo, pushed to a bare "origin" -----------------------
git init -q --bare "$T/origin.git"
git init -q --bare "$T/tap.git"
git clone -q "$T/tap.git" "$T/tapseed" 2>/dev/null
( cd "$T/tapseed" && mkdir Formula && echo old > Formula/nixenv.rb && git add . && git commit -qm init && git push -q origin HEAD:main )
git -C "$T/tap.git" symbolic-ref HEAD refs/heads/main

W="$T/work"; mkdir -p "$W/packaging/homebrew/Formula" "$W/tests"
cp "$REPO_DIR/release.sh" "$REPO_DIR/.gitignore" "$W/"
cp "$REPO_DIR/packaging/homebrew/update-formula.sh" "$W/packaging/homebrew/"
cp "$REPO_DIR/packaging/homebrew/Formula/nixenv.rb" "$W/packaging/homebrew/Formula/"
printf '#!/usr/bin/env bash\nNIXENV_VERSION="9.8.7"\necho hi\n' > "$W/nixenv.sh"
printf '#!/bin/sh\nexit 0\n' > "$W/tests/run.sh"              # stub: no recursion into this suite
chmod +x "$W/release.sh" "$W/tests/run.sh" "$W/packaging/homebrew/update-formula.sh"
( cd "$W" && git init -q && git add -A && git commit -qm init \
  && git remote add origin "$T/origin.git" && git push -q -u origin main \
  && git remote set-head origin main )

# --- fakes -------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/bin/sh
case "$1 $2" in
  "run list")  echo 4242 ;;
  "run watch") [ -f "$FAKE_FAIL" ] && exit 1; exit 0 ;;
  "run view")  echo "verify: unit tests failed" ;;
  "release view") exit 1 ;;
  *) exit 0 ;;
esac
GH
# curl: `-o FILE URL` for the tag tarball → archive of the tagged commit.
cat > "$T/bin/curl" <<'CURL'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; -*) ;; *) url="$1";; esac; shift; done
case "$url" in
  */archive/refs/tags/v*.tar.gz)
    t="${url##*/tags/}"; t="${t%.tar.gz}"
    git -C "$FAKE_ORIGIN" archive --format=tar.gz --prefix="nixenv-${t#v}/" "$t" > "$out" ;;
  *) exit 0 ;;
esac
CURL
chmod +x "$T/bin/gh" "$T/bin/curl"
export PATH="$T/bin:$PATH" FAKE_ORIGIN="$T/origin.git" FAKE_FAIL="$T/fail"
export NIXENV_REPO="fake/nixenv" TAP_URL="$T/tap.git"
rel() { ( cd "$W" && ./release.sh "$@" ) 2>&1; }

# --- preflight refusals (nothing is tagged) ----------------------------------------
out="$(rel 1.0.0 --yes)" && fail "version mismatch accepted"
assert_contains "$out" 'declares NIXENV_VERSION="9.8.7"' "version must match nixenv.sh"
echo dirty >> "$W/nixenv.sh"
out="$(rel --yes)" && fail "dirty tree accepted"
assert_contains "$out" "not clean" "refuses a dirty tree"
( cd "$W" && git checkout -q -- nixenv.sh )
( cd "$W" && echo x > x && git add x && git commit -qm local )
out="$(rel --yes)" && fail "unpushed HEAD accepted"
assert_contains "$out" "isn't pushed" "refuses an unpushed HEAD"
( cd "$W" && git push -q origin main )
[ -z "$(git -C "$T/origin.git" tag)" ] || fail "a refusal must not create a tag"

# --- a failing workflow stops before the formula -------------------------------------
: > "$FAKE_FAIL"
out="$(rel --yes)" && fail "a failed workflow must fail the release"
assert_contains "$out" "unit tests failed" "shows the failing log"
assert_contains "$out" "--retag" "says how to recover"
assert_eq "$(git -C "$T/origin.git" tag)" "v9.8.7" "the tag was pushed before waiting"
git -C "$T/tap.git" show main:Formula/nixenv.rb | grep -q old || fail "tap touched after a failed run"
rm -f "$FAKE_FAIL"

# --- the same tag on HEAD: resume, publish the formula to both repos ----------------
out="$(rel --yes)" || fail "resume failed: $out"
assert_contains "$out" "resuming" "an existing tag for this code is resumed, not re-created"
assert_contains "$out" "nixenv 9.8.7 is released" "finishes"
tapf="$(git -C "$T/tap.git" show main:Formula/nixenv.rb)"
assert_contains "$tapf" "/tags/v9.8.7.tar.gz" "tap formula points at the tag"
assert_contains "$(git -C "$T/origin.git" show main:packaging/homebrew/Formula/nixenv.rb)" \
  "/tags/v9.8.7.tar.gz" "this repo's formula committed and pushed"
[ -d "$W/homebrew-nixenv/.git" ] || fail "tap cloned into ./homebrew-nixenv"
assert_eq "$(cd "$W" && git status --porcelain)" "" "the tap clone is git-ignored"

# --- running again is a no-op ---------------------------------------------------------
n_before="$(git -C "$T/tap.git" rev-list --count main)"
out="$(rel --yes)" || fail "re-run failed: $out"
assert_contains "$out" "tap already on v9.8.7" "idempotent"
assert_eq "$(git -C "$T/tap.git" rev-list --count main)" "$n_before" "no extra tap commit"

# --- a tag elsewhere needs --retag -------------------------------------------------------
( cd "$W" && echo y > y && git add y && git commit -qm fix && git push -q origin main )
out="$(rel --yes)" && fail "a tag on another commit must not be silently reused"
assert_contains "$out" "points at" "explains the stale tag"
out="$(rel --yes --retag)" || fail "--retag failed: $out"
assert_eq "$(git -C "$T/origin.git" rev-parse 'v9.8.7^{}')" "$(git -C "$W" rev-parse HEAD~1)" \
  "tag moved to the fixed commit (HEAD~1: the formula commit came after it)"

# --- the tap clone must be ignored, or release.sh refuses --------------------------------
grep -qx '/homebrew-nixenv/' "$REPO_DIR/.gitignore" || fail ".gitignore must ignore /homebrew-nixenv/"
# ONE implementation of the sha256: release.sh delegates to update-formula.sh.
code_only < "$REPO_DIR/release.sh" | grep -qE 'sha256sum|shasum' \
  && fail "release.sh must not compute the sha256 itself — call update-formula.sh"
true
