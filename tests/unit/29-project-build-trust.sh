#!/usr/bin/env bash
# A project's flake is untrusted input built with write access to the
# shared store. It must not be able to add substituters/keys via nixConfig, nor
# read the GitHub token.
source "$(dirname "$0")/../lib.sh"
source_nixenv

body="$(cat "$REPO_DIR/nixenv.sh")"
bp="$(printf '%s' "$body" | sed -n '/^cmd_build_project()/,/^}/p' | code_only)"
assert_not_contains "$bp" "--accept-flake-config" "project builds ignore a flake's nixConfig"
assert_contains "$bp" 'NIX_CONFIG="$(nix_config_project)"' "project builds use the token-free config"
assert_not_contains "$bp" 'NIX_CONFIG="$(nix_config)"' "the base config (with token) is not used"
assert_contains "$bp" "only build flakes you trust" "the trust boundary is stated"

GITHUB_TOKEN=ghp_secret123
cfg="$(nix_config_project)"
assert_not_contains "$cfg" "ghp_secret123" "no token in the project NIX_CONFIG"
assert_not_contains "$cfg" "access-tokens" "no access-tokens line at all"
assert_contains "$cfg" "accept-flake-config = false" "flake nixConfig explicitly refused"
assert_contains "$cfg" "sandbox = true"              "sandbox requested"
# The base build (nixenv's own flake) still gets the token for rate limits.
assert_contains "$(nix_config)" "github.com=ghp_secret123" "base build keeps the token"
true
