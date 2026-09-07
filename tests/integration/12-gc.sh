#!/usr/bin/env bash
# gc: dry-run reports without deleting; a real gc keeps the live profile intact.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

# --dry-run must not shrink or break anything
before="$("$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim du -sm /nix | cut -f1)"
nx gc --dry-run >/dev/null || fail "gc --dry-run failed"
after="$("$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim du -sm /nix | cut -f1)"
[ "$after" = "$before" ] || fail "--dry-run changed the store ($before → $after MB)"

# a real gc must keep the base profile usable (it's a live GC root)
nx gc </dev/null >/dev/null || fail "gc failed"
"$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
  test -x "$PROFILE_PATH/bin/zsh" || fail "gc removed the live base profile!"
for bin in git sshd runsv caddy socat; do
  "$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
    test -x "$PROFILE_PATH/bin/$bin" || fail "gc removed $bin from the live profile"
done

# and a project can still be started from the collected store
mkproj gcp --unrestricted
nx run gcp >/dev/null || fail "project won't start after gc"
dexec gcp "$PROFILE_PATH/bin/zsh" -lc 'command -v git' >/dev/null \
  || fail "toolchain broken after gc"
