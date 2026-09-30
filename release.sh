#!/usr/bin/env bash
# =============================================================================
# release.sh — cut a nixenv release end to end
# =============================================================================
#   ./release.sh              # release the version declared in nixenv.sh
#   ./release.sh 0.3.0        # same, but assert that's the version
#   ./release.sh --yes        # no confirmation prompt
#   ./release.sh --retag      # the tag exists but is wrong: move it to HEAD
#
# Steps (each is skipped when it's already done, so re-running after a failure
# resumes where it stopped):
#   1. preflight  — on the default branch, clean tree, in sync with origin,
#                   NIXENV_VERSION matches, syntax + unit tests pass
#   2. tag        — annotated vX.Y.Z tag on HEAD, pushed
#   3. wait       — follows the `release` workflow (verify → release → formula)
#                   and prints the failing log if it breaks
#   4. formula    — pulls what the workflow committed, clones/updates the tap in
#                   ./homebrew-nixenv (git-ignored), runs update-formula.sh and
#                   pushes the formula to BOTH repos if they're not already on it
#
# Release order is fixed by the sha256: the Homebrew formula hashes the tarball
# GitHub generates for the tag, which doesn't exist until the tag is pushed.
# Needs: git, curl. `gh` (logged in) is strongly recommended — without it the
# script can only poll for the release page, not see why a workflow failed.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

REPO="${NIXENV_REPO:-rande/nixenv}"
TAP_DIR="${TAP_DIR:-$ROOT/homebrew-nixenv}"
FORMULA="packaging/homebrew/Formula/nixenv.rb"
WORKFLOW="release.yml"

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
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) die "unknown option: $1";;
    *)  version="${1#v}";;
  esac
  shift
done

confirm() {
  [ "$assume_yes" = 1 ] && return 0
  [ -t 0 ] || die "no terminal to confirm on — re-run with --yes"
  printf '%s [y/N] ' "$1"
  local a=""; read -r a || true
  case "$a" in [yY]|[yY][eE][sS]) return 0;; esac
  die "aborted — nothing was changed after this point"
}

# --- 1. preflight -------------------------------------------------------------
have git  || die "git is required"
have curl || die "curl is required (update-formula.sh downloads the tag tarball)"
[ -f nixenv.sh ] && [ -f "$FORMULA" ] || die "run this from the nixenv repository"

declared="$(sed -n 's/^NIXENV_VERSION="\([^"]*\)".*/\1/p' nixenv.sh | head -1)"
[ -n "$declared" ] || die "could not read NIXENV_VERSION from nixenv.sh"
version="${version:-$declared}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "version must be X.Y.Z (got '$version')";;
esac
if [ "$version" != "$declared" ]; then
  die "nixenv.sh declares NIXENV_VERSION=\"$declared\", not $version.
    Bump it and commit first — the workflow's verify job rejects a mismatch:
      sed -i.bak 's/^NIXENV_VERSION=.*/NIXENV_VERSION=\"$version\"/' nixenv.sh && rm nixenv.sh.bak
      git commit -am \"release $version\" && git push"
fi
tag="v$version"
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
default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
default="${default:-main}"
[ "$branch" = "$default" ] || die "on branch '$branch' — releases are cut from '$default'"

if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  die "working tree is not clean — commit or stash first (the tag must match what's pushed)"
fi

log "fetching origin"
git fetch --quiet origin "$default" --tags --force
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "origin/$default")"
if [ "$local_head" != "$remote_head" ]; then
  if git merge-base --is-ancestor "$local_head" "$remote_head"; then
    die "origin/$default has commits you don't — git pull --ff-only, then re-run"
  fi
  die "HEAD isn't pushed — git push origin $default, then re-run (the workflow builds what's on GitHub)"
fi
ok "HEAD $(git rev-parse --short HEAD) is on origin/$default"

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
    ok "$tag is already pushed for this code — resuming (workflow, then formula)";;
  elsewhere)
    if [ "$retag" != 1 ]; then
      die "$tag already exists on origin but points at ${remote_tag_sha:0:7}, not HEAD ${local_head:0:7}.
    If that tag's release failed and you've fixed it, move it:  ./release.sh --retag"
    fi;;
esac

if [ "$tag_state" != "here" ]; then
  log "syntax + unit tests (the same checks the workflow's verify job runs)"
  bash -n nixenv.sh || die "nixenv.sh has a syntax error"
  ./tests/run.sh unit >/tmp/nixenv-release-tests.log 2>&1 \
    || { tail -30 /tmp/nixenv-release-tests.log >&2; die "unit tests fail — full log: /tmp/nixenv-release-tests.log"; }
  ok "unit tests pass"
fi

have gh || warn "gh (GitHub CLI) not found — the workflow can't be followed, only waited for"

# --- 2. tag ---------------------------------------------------------------------
if [ "$tag_state" = "elsewhere" ]; then
  warn "--retag: $tag will be deleted on origin and re-created on HEAD"
  if have gh && gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    warn "a GitHub release for $tag exists and will be deleted too"
  fi
  confirm "Move $tag to $(git rev-parse --short HEAD)?"
  if have gh && gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    gh release delete "$tag" --repo "$REPO" --yes
  fi
  git push --quiet origin ":refs/tags/$tag"
  git tag -d "$tag" >/dev/null 2>&1 || true
  ok "removed the old $tag"
  tag_state="none"
fi

if [ "$tag_state" = "none" ]; then
  confirm "Tag $(git rev-parse --short HEAD) as $tag and publish nixenv $version?"
  git tag -d "$tag" >/dev/null 2>&1 || true      # a stale local-only tag
  git tag -a "$tag" -m "nixenv $version"
  git push --quiet origin "$tag"
  ok "pushed $tag"
fi

# --- 3. wait for the release workflow --------------------------------------------
if have gh; then
  log "waiting for the '$WORKFLOW' run for $tag to appear"
  run_id="" i=0
  while [ -z "$run_id" ] && [ "$i" -lt 30 ]; do
    run_id="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$tag" --limit 1 \
                --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
    [ -n "$run_id" ] || { sleep 4; i=$((i + 1)); }
  done
  [ -n "$run_id" ] || die "no '$WORKFLOW' run showed up for $tag after 2 minutes — check the Actions tab"
  log "following run $run_id (https://github.com/$REPO/actions/runs/$run_id)"
  if ! gh run watch "$run_id" --repo "$REPO" --exit-status --interval 10; then
    echo >&2
    gh run view "$run_id" --repo "$REPO" --log-failed 2>/dev/null | tail -40 >&2 || true
    die "the release workflow failed (log above). Fix it, commit, push, then: ./release.sh --retag"
  fi
  ok "workflow succeeded"
else
  log "waiting for https://github.com/$REPO/releases/tag/$tag (up to 15 min)"
  i=0
  until curl -fsI --max-time 10 "https://github.com/$REPO/releases/tag/$tag" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 90 ] || die "no release page after 15 minutes — check the Actions tab"
    sleep 10
  done
  ok "release page is up"
  sleep 20   # let the (optional) formula job finish before we look at the tap
fi

# --- 4. formula: this repo + the tap -------------------------------------------------
# The workflow's formula job may already have done this (when TAP_TOKEN is set).
# Everything below is a no-op if so.
log "syncing $default (the workflow may have committed the formula)"
git pull --quiet --ff-only origin "$default"

log "updating the formula in this repo"
./packaging/homebrew/update-formula.sh "$version" >/dev/null
if git diff --quiet -- "$FORMULA"; then
  ok "$FORMULA already on $tag"
else
  git add "$FORMULA"
  git commit --quiet -m "homebrew: nixenv $version"
  git push --quiet origin "$default"
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
