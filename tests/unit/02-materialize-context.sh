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
for p in caddy squid socat neovim zmxPkg claude-code git zsh openssh runit; do
  assert_contains "$flake" "$p" "flake has $p"
done
assert_not_contains "$flake" "tmux" "tmux removed"
assert_not_contains "$flake" "zellij" "zellij removed"

# The base ships NO language runtimes / package managers / their LSPs — those
# live in per-project flakes. Compare only the package list, since the comments
# legitimately name these as examples of what to put in a project flake.
pkglist="$(printf '%s' "$flake" | sed 's/[[:space:]]*#.*//')"
for p in nodejs_22 php85 python312 composer rustup gopls rust-analyzer \
         ruby-lsp typescript-language-server pyright intelephense; do
  assert_not_contains "$pkglist" "$p" "base flake does not ship $p"
done
for w in go typescript uv sqlite; do
  printf '%s' "$pkglist" | grep -qE "^[[:space:]]+$w\$" && fail "base flake still ships $w"
done
# what IS kept: an editor with only runtime-free servers
for p in lua-language-server bash-language-server; do
  assert_contains "$pkglist" "$p" "base keeps $p (needs no language runtime)"
done

# nvim packs must match the servers that ARE shipped (comments stripped: they
# legitimately show other packs as examples of what a project can add)
nvim="$(sed 's/^[[:space:]]*--.*//' "$CONTEXT_DIR/home-skel/.config/nvim/init.lua")"
for p in bash lua; do
  assert_contains "$nvim" "astrocommunity.pack.$p" "nvim keeps the $p pack"
done
for p in go rust ruby typescript python php; do
  assert_not_contains "$nvim" "astrocommunity.pack.$p" \
    "nvim drops the $p pack (no LSP for it in the base)"
done

# flake.lock must never be clobbered
touch "$CONTEXT_DIR/flake.lock"; echo LOCK > "$CONTEXT_DIR/flake.lock"
materialize_context
assert_eq "$(cat "$CONTEXT_DIR/flake.lock")" "LOCK" "flake.lock preserved"
