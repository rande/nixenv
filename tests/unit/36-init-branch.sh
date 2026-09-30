#!/usr/bin/env bash
# init --branch=<name>: clone a branch (or tag) instead of the default one.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# --- validation ---------------------------------------------------------------
for b in main develop release/1.2 feature/foo-bar v1.2.3 fix_42 user@work; do
  valid_git_branch "$b" || fail "should accept branch '$b'"
done
for b in "" -x --upload-pack=evil /abs trailing/ dot. a..b a//b 'x@{1}' foo.lock 'sp ace' 'semi;colon' '$(id)'; do
  valid_git_branch "$b" && fail "should reject branch '$b'"
done

# --- init rejects bad input BEFORE creating anything --------------------------
rm -rf "$NIXENV_PROJECTS_DIR"
out="$(nx init b1 --branch=develop </dev/null 2>&1)" && fail "--branch without a URL must fail"
assert_contains "$out" "--branch needs a git URL" "explains what's missing"
out="$(nx init b2 https://git.example.com/a.git --branch=-evil </dev/null 2>&1)" && fail "a branch starting with '-' must fail"
assert_contains "$out" "invalid branch name" "says why"
out="$(nx init b3 https://git.example.com/a.git --branch develop </dev/null 2>&1)" && fail "'--branch <name>' (no =) must fail clearly"
assert_contains "$out" "use --branch=<name>" "points at the right syntax"
[ -e "$NIXENV_PROJECTS_DIR/b2" ] && fail "a rejected init must not create the project"

# --- the clone passes it through, and never lets the URL be an option ----------
body="$(sed -n '/^clone_repo()/,/^}/p' "$REPO_DIR/nixenv.sh" | code_only)"
assert_contains "$body" 'git clone --branch "$2" -- "$1"' "branch passed to git clone"
assert_contains "$body" 'git clone -- "$1"' "default clone also ends options before the URL"
assert_contains "$body" '_ "$url" "$branch"' "branch handed to the clone script"
init_fn="$(sed -n '/^cmd_init()/,/^}/p' "$REPO_DIR/nixenv.sh" | code_only)"
assert_contains "$init_fn" 'clone_repo "$git_url" "$name" "$branch"' "init forwards --branch"
assert_contains "$("$REPO_DIR/nixenv.sh" --help)" "--branch=<name>" "documented in --help"
true
