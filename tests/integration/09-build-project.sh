#!/usr/bin/env bash
# Per-project flake build: template flake installs into proj profile, PATH-first.
# Heavy (nix evaluation + downloads) — opt in with NIXTEST_HEAVY=1.
source "$(dirname "$0")/../lib.sh" it
[ "${NIXTEST_HEAVY:-0}" = 1 ] || skip "heavy — set NIXTEST_HEAVY=1 to run"
sweep; trap sweep EXIT
require_store

mkproj p1 --unrestricted
nx run p1 >/dev/null

# put the repo's template flake at the app volume root
"$E" run --rm -v nxt_p1_app:/v -v "$REPO_DIR/templates":/t:ro debian:stable-slim \
  sh -c 'cp /t/flake.nix /v/flake.nix'

nx build p1 >/dev/null || fail "project build failed"

"$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
  test -x /nix/var/nix/profiles/proj-p1/bin/hello || fail "proj profile missing hello"

# PATH layering: project profile ahead of base in a fresh login shell
nx stop p1 >/dev/null; nx run p1 >/dev/null
which_hello="$(dexec p1 "$PROFILE_PATH/bin/zsh" -lc 'command -v hello')"
assert_contains "$which_hello" "proj-p1" "project profile first on PATH"
