#!/usr/bin/env bash
# Precondition test: the shared nix store exists (builds it if missing — SLOW
# the first time; later runs skip). Verifies the egress/proxy binaries too.
source "$(dirname "$0")/../lib.sh" it

if "$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
     test -x "$PROFILE_PATH/bin/zsh" >/dev/null 2>&1; then
  note "store already built"
else
  # A pinned flake.lock avoids anonymous github api resolution (rate-limited).
  if [ -f /host-flake.lock ]; then
    mkdir -p "$CONTEXT_DIR"; cp /host-flake.lock "$CONTEXT_DIR/flake.lock"
    note "seeded flake.lock from the host"
  elif [ -z "${GITHUB_TOKEN:-}" ]; then
    note "no flake.lock and no GITHUB_TOKEN — github api rate limits may bite"
  fi
  note "building the shared store (this takes a while)..."
  nx build >/dev/null || fail "base build failed"
fi

for bin in zsh git sshd runsv caddy squid socat zmx nvim; do
  "$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
    test -x "$PROFILE_PATH/bin/$bin" >/dev/null 2>&1 || fail "missing from store: $bin"
done
