#!/usr/bin/env bash
# =============================================================================
# update-formula.sh — point the Homebrew formula at a released tag
# =============================================================================
#   ./packaging/homebrew/update-formula.sh 0.2.0
#   ./packaging/homebrew/update-formula.sh 0.2.0 --check   # verify only
#
# Rewrites `url` and `sha256` together — they are the pair that rots when done
# by hand, and a mismatched sha256 fails for users, not for you.
#
# The tag must already exist on GitHub: the sha256 is computed from the tarball
# GitHub generates, which cannot be known before pushing the tag.
# =============================================================================
set -euo pipefail

REPO="${NIXENV_REPO:-rande/nixenv}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA="$HERE/Formula/nixenv.rb"
SCRIPT="$HERE/../../nixenv.sh"

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_blu=$'\033[1;34m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s✓%s %s\n'   "$c_grn" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n'   "$c_red" "$c_off" "$*" >&2; exit 1; }

version="${1:-}"
check_only=0
[ "${2:-}" = "--check" ] && check_only=1
[ -n "$version" ] || die "usage: $0 <version> [--check]   (e.g. $0 0.2.0)"
version="${version#v}"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "version must be x.y.z (got '$version')";;
esac

[ -f "$FORMULA" ] || die "formula not found: $FORMULA"
[ -f "$SCRIPT" ]  || die "nixenv.sh not found: $SCRIPT"

# The script's own version is the source of truth — `brew test` asserts
# `nixenv --version` equals the formula's version, so a mismatch here ships a
# formula whose test fails on every user's machine.
script_version="$(sed -n 's/^NIXENV_VERSION="\([^"]*\)".*/\1/p' "$SCRIPT" | head -1)"
[ -n "$script_version" ] || die "could not read NIXENV_VERSION from $SCRIPT"
if [ "$script_version" != "$version" ]; then
  die "NIXENV_VERSION is '$script_version' but you asked for '$version'
     bump it in nixenv.sh and commit BEFORE tagging:
       sed -i '' 's/^NIXENV_VERSION=.*/NIXENV_VERSION=\"$version\"/' nixenv.sh"
fi
ok "nixenv.sh declares $script_version"

url="https://github.com/$REPO/archive/refs/tags/v$version.tar.gz"
log "fetching $url"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL --max-time 60 -o "$tmp/src.tar.gz" "$url" \
  || die "could not download the tarball — is tag v$version pushed?"

# Confirm the tarball really carries this version, so a stale/retagged release
# can't be packaged silently.
tar -xzf "$tmp/src.tar.gz" -C "$tmp"
found="$(sed -n 's/^NIXENV_VERSION="\([^"]*\)".*/\1/p' "$tmp"/*/nixenv.sh 2>/dev/null | head -1)"
[ "$found" = "$version" ] \
  || die "tarball declares NIXENV_VERSION='$found', expected '$version' (retag needed)"
ok "tarball contents match v$version"

if command -v shasum >/dev/null 2>&1; then
  sha="$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)"
else
  sha="$(sha256sum "$tmp/src.tar.gz" | cut -d' ' -f1)"
fi
ok "sha256 $sha"

cur_url="$(sed -n 's/^  url "\(.*\)"$/\1/p' "$FORMULA")"
cur_sha="$(sed -n 's/^  sha256 "\(.*\)"$/\1/p' "$FORMULA")"
if [ "$cur_url" = "$url" ] && [ "$cur_sha" = "$sha" ]; then
  ok "formula already up to date"
  exit 0
fi

if [ "$check_only" = 1 ]; then
  printf 'formula is STALE:\n  url    %s\n      -> %s\n  sha256 %s\n      -> %s\n' \
    "$cur_url" "$url" "$cur_sha" "$sha"
  exit 1
fi

# In-place edit without sed -i (its syntax differs between GNU and BSD).
awk -v u="$url" -v s="$sha" '
  /^  url "/    { print "  url \"" u "\""; next }
  /^  sha256 "/ { print "  sha256 \"" s "\""; next }
                { print }
' "$FORMULA" > "$FORMULA.tmp" && mv "$FORMULA.tmp" "$FORMULA"

grep -q "$url" "$FORMULA" || die "url rewrite failed"
grep -q "$sha" "$FORMULA" || die "sha256 rewrite failed"
ok "updated $FORMULA → v$version"
log "next: copy it into the tap and push"
printf '  cp %s ../homebrew-nixenv/Formula/nixenv.rb\n' "$FORMULA"
printf '  (cd ../homebrew-nixenv && git commit -am "nixenv %s" && git push)\n' "$version"
printf '  brew update && brew upgrade nixenv\n'
