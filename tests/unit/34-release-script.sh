#!/usr/bin/env bash
# release.sh, end to end but offline: a local bare repo stands in for GitHub,
# another for the Homebrew tap, and a fake `curl` on PATH stands in for the
# GitHub REST API (release.sh needs no `gh`). The real update-formula.sh runs against a tarball of the tagged commit.
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

W="$T/work"; mkdir -p "$W/packaging/homebrew/Formula" "$W/tests" "$W/docs"
cp "$REPO_DIR/release.sh" "$REPO_DIR/.gitignore" "$W/"
cp "$REPO_DIR/packaging/homebrew/update-formula.sh" "$W/packaging/homebrew/"
cp "$REPO_DIR/packaging/homebrew/Formula/nixenv.rb" "$W/packaging/homebrew/Formula/"
printf '#!/usr/bin/env bash\nNIXENV_VERSION="9.8.6"\necho hi\n' > "$W/nixenv.sh"
printf '<b id="rev">9.8.6</b>\n' > "$W/docs/index.html"
printf '#!/bin/sh\nexit 0\n' > "$W/tests/run.sh"              # stub: no recursion into this suite
chmod +x "$W/release.sh" "$W/tests/run.sh" "$W/packaging/homebrew/update-formula.sh"
( cd "$W" && git init -q && git add -A && git commit -qm init \
  && git remote add origin "$T/origin.git" && git push -q -u origin main \
  && git remote set-head origin main )

# --- fakes -------------------------------------------------------------------------
mkdir -p "$T/bin"
# curl: `-o FILE URL` for the tag tarball → archive of the tagged commit; the
# REST API → canned JSON (FAKE_FAIL = the run failed, FAKE_RELEASE = a GitHub
# release exists). Calls are logged to FAKE_LOG, with whether a token came in.
cat > "$T/bin/curl" <<'CURL'
#!/bin/sh
out="" url="" method=GET cfg=0
while [ $# -gt 0 ]; do case "$1" in
  -o) out="$2"; shift;; -X) method="$2"; shift;; --config) cfg=1; shift;;
  -H|--max-time) shift;; -*) ;; *) url="$1";; esac; shift; done
tok=""; [ "$cfg" = 1 ] && grep -q Authorization && tok=" token"
echo "$method $url$tok" >> "$FAKE_LOG"
case "$url" in
  */archive/refs/tags/v*.tar.gz)
    t="${url##*/tags/}"; t="${t%.tar.gz}"
    git -C "$FAKE_ORIGIN" archive --format=tar.gz --prefix="nixenv-${t#v}/" "$t" > "$out" ;;
  */actions/workflows/*/runs*) echo '{"total_count":1,"workflow_runs":[{"id":4242,"name":"release"}]}' ;;
  */actions/runs/4242/jobs)
    printf '{\n  "jobs": [\n    {\n      "name": "Verify",\n      "steps": [\n'
    printf '        {\n          "name": "Set up job",\n          "status": "completed",\n          "conclusion": "success"\n        },\n'
    printf '        {\n          "name": "Unit tests",\n          "status": "completed",\n          "conclusion": "failure"\n        }\n      ]\n    }\n  ]\n}\n' ;;
  */actions/runs/4242)
    if [ -f "$FAKE_FAIL" ]; then echo '{"id":4242,"status":"completed","conclusion":"failure"}'
    else echo '{"id":4242,"status":"completed","conclusion":"success"}'; fi ;;
  */releases/tags/*) [ -f "$FAKE_RELEASE" ] || exit 22; echo '{"url":"x","id":777,"author":{"id":1}}' ;;
  */releases/777) [ "$method" = DELETE ] || exit 22 ;;
  *) exit 0 ;;
esac
CURL
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" FAKE_ORIGIN="$T/origin.git" FAKE_FAIL="$T/fail" \
  FAKE_RELEASE="$T/release" FAKE_LOG="$T/curl.log" RELEASE_POLL_INTERVAL=0
export NIXENV_REPO="fake/nixenv" TAP_URL="$T/tap.git"
unset GITHUB_TOKEN; export GITHUB_TOKEN_FILE="$T/no-token"   # never the real one
rel() { ( cd "$W" && ./release.sh "$@" ) 2>&1; }

# --- preflight refusals (nothing is bumped, committed or tagged) ---------------------
out="$(rel --yes)" && fail "a release without a version accepted"
assert_contains "$out" "mandatory" "the version argument is mandatory"
out="$(rel 9.8 --yes)" && fail "a malformed version accepted"
assert_contains "$out" "X.Y.Z" "rejects a malformed version"
( cd "$W" && git checkout -q -b feature )
out="$(rel 9.8.7 --yes)" && fail "a release off main accepted"
assert_contains "$out" "from 'main' only" "refuses any branch but main"
( cd "$W" && git checkout -q main && git branch -q -D feature )
echo dirty >> "$W/README"; ( cd "$W" && git add README )
out="$(rel 9.8.7 --yes)" && fail "dirty tree accepted"
assert_contains "$out" "uncommitted changes" "refuses a dirty tree"
( cd "$W" && git rm -q --cached README && rm README )
( cd "$W" && git commit -q --allow-empty -m ahead && git push -q origin main && git reset -q --hard HEAD~1 )
out="$(rel 9.8.7 --yes)" && fail "a stale main accepted"
assert_contains "$out" "has commits you don't" "refuses when behind origin"
( cd "$W" && git pull -q --ff-only origin main )
[ -z "$(git -C "$T/origin.git" tag)" ] || fail "a refusal must not create a tag"
assert_contains "$(cat "$W/nixenv.sh")" 'NIXENV_VERSION="9.8.6"' "a refusal leaves nixenv.sh alone"

# --- tests failing after the bump: nothing committed, the bump is undone ---------------
printf '#!/bin/sh\nexit 1\n' > "$W/tests/run.sh"; ( cd "$W" && git commit -qam "failing tests" && git push -q origin main )
out="$(rel 9.8.7 --yes)" && fail "failing unit tests accepted"
assert_contains "$out" "unit tests fail" "stops on failing tests"
assert_eq "$(cd "$W" && git status --porcelain --untracked-files=no)" "" "the bump is reverted"
printf '#!/bin/sh\nexit 0\n' > "$W/tests/run.sh"; ( cd "$W" && git commit -qam "passing tests" && git push -q origin main )

# --- bump + commit + tag; a failing workflow stops before the formula ---------------
echo scratch > "$W/untracked.txt"                        # must not be committed
: > "$FAKE_FAIL"
out="$(rel 9.8.7 --yes)" && fail "a failed workflow must fail the release"
assert_eq "$(git -C "$T/origin.git" log -1 --format=%s main)" "release 9.8.7" "release commit pushed to main"
assert_eq "$(git -C "$T/origin.git" show --name-only --format= main | sort | tr '\n' ' ')" \
  "docs/index.html nixenv.sh " "the release commit holds ONLY nixenv.sh and docs/index.html"
assert_contains "$(git -C "$T/origin.git" show main:nixenv.sh)" 'NIXENV_VERSION="9.8.7"' "NIXENV_VERSION bumped"
assert_contains "$(git -C "$T/origin.git" show main:docs/index.html)" '<b id="rev">9.8.7</b>' "site rev bumped"
assert_eq "$(git -C "$T/origin.git" rev-parse 'v9.8.7^{}')" "$(git -C "$T/origin.git" rev-parse main)" \
  "the tag is on the release commit"
[ -f "$W/untracked.txt" ] && rm "$W/untracked.txt"
assert_contains "$out" "failed step: Unit tests" "names the failing step"
assert_contains "$out" "github.com/fake/nixenv/actions/runs/4242" "links the run"
assert_contains "$out" "--retag" "says how to recover"
assert_eq "$(git -C "$T/origin.git" tag)" "v9.8.7" "the tag was pushed before waiting"
git -C "$T/tap.git" show main:Formula/nixenv.rb | grep -q old || fail "tap touched after a failed run"
rm -f "$FAKE_FAIL"

# --- the same tag on HEAD: resume, publish the formula to both repos ----------------
out="$(rel 9.8.7 --yes)" || fail "resume failed: $out"
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
out="$(rel 9.8.7 --yes)" || fail "re-run failed: $out"
assert_contains "$out" "tap already on v9.8.7" "idempotent"
assert_eq "$(git -C "$T/tap.git" rev-list --count main)" "$n_before" "no extra tap commit"

# --- a tag elsewhere needs --retag -------------------------------------------------------
( cd "$W" && echo y > y && git add y && git commit -qm fix && git push -q origin main )
out="$(rel 9.8.7 --yes)" && fail "a tag on another commit must not be silently reused"
assert_contains "$out" "points at" "explains the stale tag"
# A failed GitHub release must go too: refused without a token...
: > "$FAKE_RELEASE"
out="$(rel 9.8.7 --yes --retag)" && fail "--retag with a release and no token must refuse"
assert_contains "$out" "needs a token" "explains why"
# ...deleted through the API with one (sent via --config, not argv).
: > "$FAKE_LOG"
out="$(GITHUB_TOKEN=ghp_test rel 9.8.7 --yes --retag)" || fail "--retag failed: $out"
grep -q "^DELETE .*/repos/fake/nixenv/releases/777 token$" "$FAKE_LOG" || fail "release not deleted with the token: $(cat "$FAKE_LOG")"
rm -f "$FAKE_RELEASE"
assert_eq "$(git -C "$T/origin.git" rev-parse 'v9.8.7^{}')" "$(git -C "$W" rev-parse HEAD~1)" \
  "tag moved to the fixed commit (HEAD~1: the formula commit came after it)"

# --- the tap clone must be ignored, or release.sh refuses --------------------------------
grep -qx '/homebrew-nixenv/' "$REPO_DIR/.gitignore" || fail ".gitignore must ignore /homebrew-nixenv/"
# No GitHub CLI dependency.
code_only < "$REPO_DIR/release.sh" | grep -qE '(^|[^a-z_-])gh( |$)' && fail "release.sh must not call gh"
# The tag push shows git's output: hidden, a credential prompt looks like a hang.
code_only < "$REPO_DIR/release.sh" | grep -E 'git push .*"refs/tags/\$tag"' | grep -q -- '--quiet' && fail "tag push must not be --quiet"
# ONE implementation of the sha256: release.sh delegates to update-formula.sh.
code_only < "$REPO_DIR/release.sh" | grep -qE 'sha256sum|shasum' \
  && fail "release.sh must not compute the sha256 itself — call update-formula.sh"
true
