#!/usr/bin/env bash
# =============================================================================
# release.sh — cut a nixenv release end to end
# =============================================================================
#   ./release.sh 0.4.0          # bump, commit, tag and publish nixenv 0.4.0
#   ./release.sh 0.4.0 --yes    # no confirmation prompt
#   ./release.sh 0.4.0 --retag  # the tag exists but is wrong: move it to HEAD
#
# The version is mandatory. Steps (each is skipped when it's already done, so
# re-running after a failure resumes where it stopped):
#   1. preflight  — on main, clean tree, not behind origin/main
#   2. bump       — NIXENV_VERSION in nixenv.sh + the rev in docs/index.html;
#                   syntax + unit tests; commits ONLY those two files
#                   ("release X.Y.Z"), nothing else is staged
#   3. tag        — annotated vX.Y.Z tag on that commit; main and the tag are
#                   pushed together (--atomic: both or neither)
#   4. wait       — follows the `release` workflow (verify → release → formula)
#                   through GitHub's REST API and names the failing step
#   5. formula    — pulls what the workflow committed, clones/updates the tap in
#                   ./homebrew-nixenv (git-ignored), runs update-formula.sh and
#                   pushes the formula to BOTH repos if they're not already on it
#
# Release order is fixed by the sha256: the Homebrew formula hashes the tarball
# GitHub generates for the tag, which doesn't exist until the tag is pushed.
# Needs: git, curl. No GitHub CLI: the workflow is followed through the public
# REST API. A token is optional ($GITHUB_TOKEN, else ~/.nixenv/github_token):
# it lifts the 60 requests/hour anonymous limit, and --retag needs one to delete
# a failed GitHub release.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

REPO="${NIXENV_REPO:-rande/nixenv}"
TAP_DIR="${TAP_DIR:-$ROOT/homebrew-nixenv}"
FORMULA="packaging/homebrew/Formula/nixenv.rb"
WORKFLOW="release.yml"
API="${GITHUB_API:-https://api.github.com}"
POLL="${RELEASE_POLL_INTERVAL:-15}"     # seconds between workflow polls

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_blu=$'\033[1;34m'; c_off=$'\033[0m'
if [ ! -t 1 ]; then c_red=""; c_grn=""; c_yel=""; c_blu=""; c_off=""; fi
log()  { printf '%s==>%s %s\n' "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s✓%s %s\n'   "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n'   "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s✗%s %s\n'   "$c_red" "$c_off" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- arguments ----------------------------------------------------------------
version="" assume_yes=0 retag=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) assume_yes=1;;
    --retag)  retag=1;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) die "unknown option: $1";;
    *)  [ -z "$version" ] || die "one version only (got '$version' and '$1')"
        version="${1#v}";;
  esac
  shift
done
[ -n "$version" ] || die "usage: ./release.sh <X.Y.Z> [--yes] [--retag]   (the version is mandatory)"
# Strict: it is written into nixenv.sh and a sed replacement below.
printf '%s\n' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "version must be X.Y.Z (got '$version')"
tag="v$version"

confirm() {
  [ "$assume_yes" = 1 ] && return 0
  [ -t 0 ] || die "no terminal to confirm on — re-run with --yes"
  printf '%s [y/N] ' "$1"
  local a=""; read -r a || true
  case "$a" in [yY]|[yY][eE][sS]) return 0;; esac
  die "aborted — nothing was changed after this point"
}

# --- 1. preflight -------------------------------------------------------------
BRANCH=main            # releases are cut from main, and only main
SCRIPT=nixenv.sh
SITE=docs/index.html
have git  || die "git is required"
have curl || die "curl is required (update-formula.sh downloads the tag tarball)"
[ -f "$SCRIPT" ] && [ -f "$SITE" ] && [ -f "$FORMULA" ] || die "run this from the nixenv repository"
grep -q '^NIXENV_VERSION="' "$SCRIPT" || die "could not find NIXENV_VERSION in $SCRIPT"
grep -q '<b id="rev">[^<]*</b>' "$SITE" || die "could not find <b id=\"rev\"> in $SITE"
ok "releasing nixenv $version ($tag)"

# The tap clone lives inside this repo; it must never be committed here.
# (trailing slash: a dir-only pattern like /homebrew-nixenv/ doesn't match a
# path that doesn't exist yet unless git is told it's a directory)
if ! git check-ignore -q "$TAP_DIR/" 2>/dev/null; then
  case "$TAP_DIR" in
    "$ROOT"/*) die "$(basename "$TAP_DIR")/ is not git-ignored — add '/$(basename "$TAP_DIR")/' to .gitignore first";;
  esac
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "$BRANCH" ] || die "on branch '$branch' — releases are cut from '$BRANCH' only"

# Tracked changes would be tested (the unit suite runs on the working tree) but
# not released; untracked files are ignored — only $SCRIPT and $SITE get staged.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git status --short --untracked-files=no >&2
  die "working tree has uncommitted changes — commit or stash first (the tag must match what's tested)"
fi

log "fetching origin"
git fetch --quiet origin "$BRANCH" --tags --force
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "origin/$BRANCH")"
if [ "$local_head" != "$remote_head" ] && ! git merge-base --is-ancestor "$remote_head" "$local_head"; then
  if git merge-base --is-ancestor "$local_head" "$remote_head"; then
    die "origin/$BRANCH has commits you don't — git pull --ff-only, then re-run"
  fi
  die "$BRANCH and origin/$BRANCH have diverged — reconcile them, then re-run"
fi
ahead="$(git rev-list --count "$remote_head..$local_head")"

# Where does the tag stand? none | here (points at HEAD) | elsewhere
tag_state="none"
remote_tag_sha="$(git ls-remote origin "refs/tags/$tag^{}" | cut -f1)"
[ -n "$remote_tag_sha" ] || remote_tag_sha="$(git ls-remote origin "refs/tags/$tag" | cut -f1)"
if [ -n "$remote_tag_sha" ]; then
  if [ "$remote_tag_sha" = "$local_head" ]; then
    tag_state="here"
  # After a release, main moves past the tag by exactly the formula commit (ours
  # or the workflow's). That's still THIS release — anything else changed means
  # the tag is stale.
  elif git merge-base --is-ancestor "$remote_tag_sha" "$local_head" 2>/dev/null \
       && [ -z "$(git diff --name-only "$remote_tag_sha" "$local_head" -- . ":(exclude)$FORMULA")" ]; then
    tag_state="here"
  else
    tag_state="elsewhere"
  fi
fi

case "$tag_state" in
  here)
    [ "$ahead" = 0 ] || die "$tag is released but $BRANCH has $ahead unpushed commit(s) — push them first"
    ok "$tag is already pushed for this code — resuming (workflow, then formula)";;
  elsewhere)
    if [ "$retag" != 1 ]; then
      die "$tag already exists on origin but points at ${remote_tag_sha:0:7}, not HEAD ${local_head:0:7}.
    If that tag's release failed and you've fixed it, move it:  ./release.sh $version --retag"
    fi;;
esac

# --- 2. bump --------------------------------------------------------------------
bumped=0
if [ "$tag_state" != "here" ]; then
  # -i.bak + rm: the one in-place form GNU and BSD (macOS) sed both accept.
  sed -i.bak "s/^NIXENV_VERSION=\"[^\"]*\"/NIXENV_VERSION=\"$version\"/" "$SCRIPT" && rm -f "$SCRIPT.bak"
  sed -i.bak "s|<b id=\"rev\">[^<]*</b>|<b id=\"rev\">$version</b>|" "$SITE" && rm -f "$SITE.bak"
  grep -q "^NIXENV_VERSION=\"$version\"" "$SCRIPT" || die "failed to set NIXENV_VERSION in $SCRIPT"
  grep -q "<b id=\"rev\">$version</b>" "$SITE"     || die "failed to set the rev in $SITE"
  if git diff --quiet -- "$SCRIPT" "$SITE"; then
    ok "$SCRIPT and $SITE already say $version"
  else
    bumped=1
    git --no-pager diff --stat -- "$SCRIPT" "$SITE"
  fi

  # Undo the bump if anything below fails before it is committed.
  restore() { [ "$bumped" = 1 ] && git checkout --quiet -- "$SCRIPT" "$SITE" 2>/dev/null || true; }
  trap restore EXIT

  log "syntax + unit tests (the same checks the workflow's verify job runs)"
  bash -n "$SCRIPT" || die "$SCRIPT has a syntax error"
  ./tests/run.sh unit >/tmp/nixenv-release-tests.log 2>&1 \
    || { tail -30 /tmp/nixenv-release-tests.log >&2; die "unit tests fail — full log: /tmp/nixenv-release-tests.log"; }
  ok "unit tests pass"
fi

# --- GitHub REST API (curl only) ------------------------------------------------------
# The repo is public, so reads work anonymously (60 requests/hour per IP). A
# token raises that and allows deleting a release; it goes to curl on stdin
# (--config -), never on the command line where `ps` would show it.
api_token="${GITHUB_TOKEN:-}"
[ -n "$api_token" ] || api_token="$(cat "${GITHUB_TOKEN_FILE:-$HOME/.nixenv/github_token}" 2>/dev/null || true)"
case "$api_token" in *[!A-Za-z0-9_]*) api_token="";; esac   # one line, token charset only
api() {   # api [METHOD] <path under /repos/$REPO/>  → body on stdout, non-zero on HTTP error
  local method=GET
  [ "$#" -gt 1 ] && { method="$1"; shift; }
  { if [ -n "$api_token" ]; then printf 'header = "Authorization: Bearer %s"\n' "$api_token"; fi; } \
    | curl -fsS --max-time 20 --config - -X "$method" \
        -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        "$API/repos/$REPO/$1"
}
# First value of a top-level-ish "key": in a JSON body (compact or pretty). Good
# enough for the fields used here, which GitHub lists before any nested object.
json_first() {
  tr -s ' \t\r\n' ' ' | sed 's/": /":/g' | grep -oE "\"$1\":(\"[^\"]*\"|[0-9a-z]+)" \
    | head -1 | sed -E "s/^\"$1\"://; s/^\"//; s/\"$//"
}

# --- 3. tag ---------------------------------------------------------------------
if [ "$tag_state" = "elsewhere" ]; then
  warn "--retag: $tag will be deleted on origin and re-created on the release commit"
  release_id="$(api "releases/tags/$tag" 2>/dev/null | json_first id || true)"
  if [ -n "$release_id" ]; then
    [ -n "$api_token" ] || die "a GitHub release for $tag exists, and deleting it needs a token.
    Delete it at https://github.com/$REPO/releases/tag/$tag (or set GITHUB_TOKEN), then re-run --retag"
    warn "the GitHub release for $tag will be deleted too"
  fi
  confirm "Move $tag?"
  if [ -n "$release_id" ]; then
    api DELETE "releases/$release_id" >/dev/null || die "could not delete the GitHub release for $tag (token lacks Contents: write?)"
  fi
  git push --quiet origin ":refs/tags/$tag"
  git tag -d "$tag" >/dev/null 2>&1 || true
  ok "removed the old $tag"
  tag_state="none"
fi

if [ "$tag_state" = "none" ]; then
  if [ "$bumped" = 1 ]; then
    what="commit $SCRIPT + $SITE as \"release $version\", tag it $tag"
  else
    what="tag $(git rev-parse --short HEAD) as $tag"
  fi
  [ "$ahead" = 0 ] || what="$what (also pushes $ahead unpushed commit(s) on $BRANCH)"
  confirm "Release nixenv $version: $what, and push?"
  if [ "$bumped" = 1 ]; then
    # Pathspec commit: exactly these two files, whatever else is in the index.
    git commit --quiet -m "release $version" -- "$SCRIPT" "$SITE"
    bumped=0                                   # committed: nothing to restore
    ok "committed $(git rev-parse --short HEAD) release $version"
  fi
  git tag -d "$tag" >/dev/null 2>&1 || true      # a stale local-only tag
  log "creating $tag (if tag signing is on, gpg may ask for its passphrase)"
  git tag -a "$tag" -m "nixenv $version"
  # Not --quiet: a push waiting for credentials (keychain dialog, browser login,
  # ssh passphrase) looks exactly like a hang when its output is hidden.
  # --atomic: a tag on GitHub whose commit isn't on main (or the reverse) is a
  # half release; the workflow would build it anyway.
  log "pushing $BRANCH and $tag to origin (git may ask for credentials)"
  git push --atomic origin "refs/heads/$BRANCH" "refs/tags/$tag"
  ok "pushed $BRANCH and $tag"
fi

# --- 4. wait for the release workflow --------------------------------------------
tag_sha="$(git rev-parse "$tag^{commit}")"
log "waiting for the '$WORKFLOW' run for $tag to appear"
run_id="" i=0
while [ -z "$run_id" ]; do
  # head_sha too: after --retag, an older run for the same tag name may exist.
  run_id="$(api "actions/workflows/$WORKFLOW/runs?event=push&branch=$tag&head_sha=$tag_sha&per_page=1" 2>/dev/null \
              | json_first id || true)"
  [ -n "$run_id" ] && break
  i=$((i + 1)); [ "$i" -lt 30 ] || die "no '$WORKFLOW' run showed up for $tag — check https://github.com/$REPO/actions"
  sleep 4
done
run_url="https://github.com/$REPO/actions/runs/$run_id"
log "following run $run_id ($run_url)"
status="" conclusion="" errs=0 last=""
while :; do
  if body="$(api "actions/runs/$run_id" 2>/dev/null)"; then
    errs=0
    status="$(printf '%s' "$body" | json_first status)"
    conclusion="$(printf '%s' "$body" | json_first conclusion)"
    [ "$status" = "$last" ] || { log "  $status"; last="$status"; }
    [ "$status" = completed ] && break
  else
    errs=$((errs + 1))
    [ "$errs" -lt 5 ] || die "GitHub API keeps failing (rate limit? set GITHUB_TOKEN) — follow it at $run_url, then re-run ./release.sh $version"
  fi
  sleep "$POLL"
done
if [ "$conclusion" != success ]; then
  # Steps are listed as {"name","status","conclusion"}: name the failed ones.
  failed="$(api "actions/runs/$run_id/jobs" 2>/dev/null | tr -s ' \t\r\n' ' ' | sed 's/": /":/g; s/, /,/g' \
             | grep -oE '"name":"[^"]*","status":"[^"]*","conclusion":"failure"' \
             | sed -E 's/^"name":"([^"]*)".*/\1/' || true)"
  echo >&2
  [ -z "$failed" ] || printf '%s\n' "$failed" | sed 's/^/   failed step: /' >&2
  die "the release workflow ended '$conclusion' — logs: $run_url
    Fix it, commit, push, then: ./release.sh $version --retag"
fi
ok "workflow succeeded"

# --- 5. formula: this repo + the tap -------------------------------------------------
# The workflow's formula job may already have done this (when TAP_TOKEN is set).
# Everything below is a no-op if so.
log "syncing $BRANCH (the workflow may have committed the formula)"
git pull --quiet --ff-only origin "$BRANCH"

log "updating the formula in this repo"
./packaging/homebrew/update-formula.sh "$version" >/dev/null
if git diff --quiet -- "$FORMULA"; then
  ok "$FORMULA already on $tag"
else
  git add "$FORMULA"
  git commit --quiet -m "homebrew: nixenv $version"
  git push --quiet origin "$BRANCH"
  ok "committed and pushed $FORMULA"
fi

# Tap URL: same host and transport as origin (so ssh vs https matches your setup).
origin_url="$(git remote get-url origin)"
tap_url="${TAP_URL:-$(printf '%s' "$origin_url" | sed -E 's#/[^/]+(\.git)?$#/homebrew-nixenv.git#')}"
if [ -d "$TAP_DIR/.git" ]; then
  log "updating the tap clone in $(basename "$TAP_DIR")/"
  git -C "$TAP_DIR" pull --quiet --ff-only
else
  log "cloning the tap $tap_url → $(basename "$TAP_DIR")/"
  git clone --quiet "$tap_url" "$TAP_DIR" \
    || die "could not clone $tap_url — create the tap repo first (see RELEASING.md), or set TAP_URL"
fi

mkdir -p "$TAP_DIR/Formula"
cp "$FORMULA" "$TAP_DIR/Formula/nixenv.rb"
if [ -z "$(git -C "$TAP_DIR" status --porcelain -- Formula/nixenv.rb)" ]; then
  ok "tap already on $tag"
else
  git -C "$TAP_DIR" add Formula/nixenv.rb
  git -C "$TAP_DIR" commit --quiet -m "nixenv $version"
  git -C "$TAP_DIR" push --quiet
  ok "pushed the formula to the tap"
fi

grep -q "/tags/$tag.tar.gz" "$TAP_DIR/Formula/nixenv.rb" \
  || die "the tap's formula doesn't point at $tag — inspect $TAP_DIR/Formula/nixenv.rb"

echo
ok "nixenv $version is released"
echo "   release:  https://github.com/$REPO/releases/tag/$tag"
echo "   check it the way users will:"
echo "     brew update && brew upgrade nixenv    # or: brew install ${REPO%/*}/nixenv/nixenv"
echo "     nixenv --version                      # → nixenv $version"
