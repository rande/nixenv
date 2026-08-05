#!/usr/bin/env bash
# materialize_context writes every embedded file; generated shell parses.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$CONTEXT_DIR"
materialize_context

for f in flake.nix Dockerfile entrypoint.sh \
         home-skel/.zshrc home-skel/.gitconfig home-skel/.gitignore \
         home-skel/.config/starship.toml home-skel/.vimrc \
         home-skel/.config/nvim/init.lua home-skel/.ssh/config; do
  assert_file "$CONTEXT_DIR/$f"
done

sh -n "$CONTEXT_DIR/entrypoint.sh" || fail "entrypoint.sh does not parse"

# flake contains the expected key packages
flake="$(cat "$CONTEXT_DIR/flake.nix")"
for p in caddy squid socat neovim zmxPkg claude-code; do
  assert_contains "$flake" "$p" "flake has $p"
done
assert_not_contains "$flake" "tmux" "tmux removed"
assert_not_contains "$flake" "zellij" "zellij removed"

# flake.lock must never be clobbered
touch "$CONTEXT_DIR/flake.lock"; echo LOCK > "$CONTEXT_DIR/flake.lock"
materialize_context
assert_eq "$(cat "$CONTEXT_DIR/flake.lock")" "LOCK" "flake.lock preserved"
