#!/usr/bin/env bash
# =============================================================================
# dev/embed-flake-lock.sh — ship the base flake's lock inside nixenv.sh (TOOL-09)
# =============================================================================
# Run on the HOST from a clone, after the lock you want to ship was produced:
#
#   ./nixenv.sh update                 # resolves the inputs, rebuilds, writes
#                                      # ~/.nixenv/context/flake.lock
#   ./dev/embed-flake-lock.sh          # copies it into nixenv.sh
#   ./dev/embed-flake-lock.sh <file>   # or from another lock file
#
# It replaces the body of the NIXENV_FLAKE_LOCK heredoc in nixenv.sh, after
# checking the file is a flake lock for exactly the base flake's inputs.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/nixenv.sh"
lock="${1:-${CONTEXT_DIR:-$HOME/.nixenv/context}/flake.lock}"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
[ -f "$lock" ] || die "no lock at $lock — run './nixenv.sh update' first, or pass a file"
grep -q "^  cat <<'NIXENV_FLAKE_LOCK'\$" "$SCRIPT" || die "no NIXENV_FLAKE_LOCK heredoc in $SCRIPT"
grep -qx 'NIXENV_FLAKE_LOCK' "$lock" && die "$lock contains the heredoc delimiter"

# The lock must pin exactly the inputs the embedded flake declares.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$lock" <<'CHECK' || die "$lock is not a lock for the base flake (inputs nixpkgs + nixpkgs-unstable)"
import json, sys
d = json.load(open(sys.argv[1]))
root = d["nodes"][d["root"]]["inputs"]
assert sorted(root) == ["nixpkgs", "nixpkgs-unstable"], root
for name in root:
    assert "narHash" in d["nodes"][root[name]]["locked"], name
CHECK
else
  grep -q '"nixpkgs-unstable"' "$lock" || die "$lock does not pin nixpkgs-unstable"
fi

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
awk -v lockfile="$lock" '
  $0 == "  cat <<'"'"'NIXENV_FLAKE_LOCK'"'"'" {
    print; while ((getline l < lockfile) > 0) print l; skip = 1; next }
  skip && $0 == "NIXENV_FLAKE_LOCK" { skip = 0 }
  !skip { print }
' "$SCRIPT" > "$tmp"
bash -n "$tmp" || die "the result does not parse — nixenv.sh left unchanged"
cat "$tmp" > "$SCRIPT"   # in place: keeps the file's mode
printf '✓ embedded %s into nixenv.sh — run ./tests/run.sh, then commit\n' "$lock"
