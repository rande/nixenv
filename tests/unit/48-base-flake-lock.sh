#!/usr/bin/env bash
# TOOL-09: the base flake's lock ships in nixenv.sh, seeds a MISSING
# $CONTEXT_DIR/flake.lock only, and dev/embed-flake-lock.sh refreshes it.
source "$(dirname "$0")/../lib.sh"
source_nixenv

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Whatever is embedded must be a lock for exactly the base flake's inputs.
emb="$(embedded_flake_lock)"
if [ -n "$emb" ]; then
  printf '%s\n' "$emb" | python3 -c '
import json, sys
d = json.load(sys.stdin)
root = d["nodes"][d["root"]]["inputs"]
assert sorted(root) == ["nixpkgs", "nixpkgs-unstable"], root
for n in root:
    assert "narHash" in d["nodes"][root[n]]["locked"], n
' || fail "the embedded flake.lock does not match the base flake's inputs"
else
  note "no lock embedded yet (release.sh warns): ./nixenv.sh update && ./dev/embed-flake-lock.sh"
fi
inputs="$(sed -n "/<<'NIXENV_FLAKE'/,/^NIXENV_FLAKE\$/p" "$NIXENV_SH" | grep -o 'inputs\.[a-z-]*\.url' | sort | tr '\n' ' ')"
assert_eq "$inputs" "inputs.nixpkgs-unstable.url inputs.nixpkgs.url " "the base flake's inputs (update the lock check if they change)"

# Embed a lock into a COPY of the script, then check seeding.
mkdir -p "$T/repo/dev"
cp "$NIXENV_SH" "$T/repo/nixenv.sh"; cp "$REPO_DIR/dev/embed-flake-lock.sh" "$T/repo/dev/"
cat > "$T/lock" <<'LOCK'
{
  "nodes": {
    "nixpkgs": { "locked": { "narHash": "sha256-A=", "owner": "NixOS", "repo": "nixpkgs", "rev": "a", "type": "github" } },
    "nixpkgs-unstable": { "locked": { "narHash": "sha256-B=", "owner": "NixOS", "repo": "nixpkgs", "rev": "b", "type": "github" } },
    "root": { "inputs": { "nixpkgs": "nixpkgs", "nixpkgs-unstable": "nixpkgs-unstable" } }
  },
  "root": "root",
  "version": 7
}
LOCK
"$T/repo/dev/embed-flake-lock.sh" "$T/lock" >/dev/null || fail "embedding a valid lock"
"$T/repo/dev/embed-flake-lock.sh" "$T/lock" >/dev/null || fail "embedding again (idempotent)"
bash -n "$T/repo/nixenv.sh" || fail "the script still parses"
got="$(bash -c 'source "$1"; embedded_flake_lock' _ "$T/repo/nixenv.sh")"
assert_eq "$got" "$(cat "$T/lock")" "the lock is embedded verbatim"

ctx="$T/ctx"
( source "$T/repo/nixenv.sh"; CONTEXT_DIR="$ctx"; materialize_context )
assert_eq "$(cat "$ctx/flake.lock")" "$(cat "$T/lock")" "a missing lock is seeded"
echo '{"mine":1}' > "$ctx/flake.lock"
( source "$T/repo/nixenv.sh"; CONTEXT_DIR="$ctx"; materialize_context )
assert_eq "$(cat "$ctx/flake.lock")" '{"mine":1}' "an existing lock (update's) is never replaced"

echo '{"nodes":{"r":{"inputs":{"nixpkgs":"x"}}},"root":"r"}' > "$T/bad"
if "$T/repo/dev/embed-flake-lock.sh" "$T/bad" >/dev/null 2>&1; then fail "a lock for other inputs is refused"; fi
assert_contains "$(cat "$REPO_DIR/release.sh")" "NIXENV_FLAKE_LOCK" "release.sh checks the embedded lock"
true
