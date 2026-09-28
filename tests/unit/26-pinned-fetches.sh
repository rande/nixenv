#!/usr/bin/env bash
# The base flake is PURE — zmx is fetched by URL + sha256, and the base
# build no longer passes --impure. A changed upstream tarball must fail the build.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$CONTEXT_DIR"; materialize_context
flake="$(code_only < "$CONTEXT_DIR/flake.nix")"

assert_not_contains "$flake" "builtins.fetchTarball" "no unpinned fetchTarball"
assert_not_contains "$flake" "builtins.fetchurl"     "no unpinned builtins.fetchurl"
assert_not_contains "$flake" "getEnv"                 "no environment reads"
assert_contains "$flake" 'zmxVersion = "0.8.1"'       "zmx pinned to 0.8.1"
assert_contains "$flake" "pkgs.fetchurl"              "zmx fetched with a hash"
assert_contains "$flake" "sha256 = zmxHashes.\${system}" "hash chosen per system"
# The two hashes, as published by upstream (zmx.sh/a/<asset>.sha256 and the
# GitHub release digest agree on both).
assert_contains "$flake" 'x86_64-linux  = "dfd75720b942466f28870731cc86dbc07afa72fb8f3bd5eeb4ff707e4eecebe8"'
assert_contains "$flake" 'aarch64-linux = "943eb44c812333fd450da12097521afd3339436e86f8c2ac618b905c4c9ece68"'
# Every system the flake builds for has a hash.
for s in $(printf '%s' "$flake" | sed -n 's/.*systems = \[\(.*\)\];.*/\1/p' | tr -d '"'); do
  printf '%s' "$flake" | grep -qE "^[[:space:]]+$s[[:space:]]+= \"[0-9a-f]{64}\";" \
    || fail "no zmx sha256 for $s"
done

build_fn="$(sed -n '/^cmd_build()/,/^}/p' "$REPO_DIR/nixenv.sh" | code_only)"
assert_not_contains "$build_fn" "--impure" "base build is pure"
true
