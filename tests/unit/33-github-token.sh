#!/usr/bin/env bash
# The optional GitHub token: asked once, stored 600, only given to nixenv's own
# builds, and a rate-limited build explains itself.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -f "$GITHUB_TOKEN_FILE" "$GITHUB_TOKEN_SKIP"; unset GITHUB_TOKEN

# --- the link pre-fills a read-only, public-repos-only fine-grained token ------
case "$GITHUB_TOKEN_URL" in
  https://github.com/settings/personal-access-tokens/new\?*) ;;
  *) fail "unexpected token URL: $GITHUB_TOKEN_URL";;
esac
assert_contains "$GITHUB_TOKEN_URL" "name=nixenv" "token is named"
# No permission parameters at all: the default is public repositories, read-only.
for perm in contents= metadata= administration= workflows= pull_requests=; do
  assert_not_contains "$GITHUB_TOKEN_URL" "&$perm" "no extra permission ($perm)"
done

# --- validation: the token lands in NIX_CONFIG ---------------------------------
valid_github_token "github_pat_11ABCDEF0_abcdefXYZ" || fail "fine-grained token accepted"
valid_github_token "ghp_abcdef1234567890"          || fail "classic token accepted"
for bad in "" "hello" "ghp_abc def" 'ghp_x
access-tokens = evil'; do
  valid_github_token "$bad" && fail "invalid token accepted: [$bad]"
done

# --- non-interactive first build: explains, never prompts, doesn't give up forever
out="$(ensure_github_token </dev/null 2>&1)"
assert_contains "$out" "60 anonymous" "explains the anonymous limit"
assert_contains "$out" "shared" "mentions shared IPs"
assert_contains "$out" "$GITHUB_TOKEN_URL" "prints the pre-filled link"
assert_contains "$out" "no terminal" "says why it didn't ask"
[ -e "$GITHUB_TOKEN_SKIP" ] && fail "a non-interactive run must not record 'don't ask again'"

# --- stored token flows into nix_config, env wins ------------------------------
save_github_token "ghp_stored123" >/dev/null 2>&1
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
assert_eq "$(perm "$GITHUB_TOKEN_FILE")" "600" "token file is 600"
assert_contains "$(nix_config)" "access-tokens = github.com=ghp_stored123" "stored token used"
assert_contains "$(GITHUB_TOKEN=ghp_fromenv nix_config)" "github.com=ghp_fromenv" "env var wins"
assert_eq "$(ensure_github_token </dev/null 2>&1)" "" "silent once a token exists"
# A tampered file can't inject nix settings.
printf 'ghp_x\naccess-tokens = github.com=evil\n' > "$GITHUB_TOKEN_FILE"
assert_not_contains "$(nix_config)" "access-tokens" "invalid stored token ignored"
# Project builds never get it.
save_github_token "ghp_stored123" >/dev/null 2>&1
assert_not_contains "$(nix_config_project)" "ghp_stored123" "project builds get no token"

# --- 'don't ask again' ----------------------------------------------------------
rm -f "$GITHUB_TOKEN_FILE"; : > "$GITHUB_TOKEN_SKIP"
assert_eq "$(ensure_github_token </dev/null 2>&1)" "" "skip marker respected"
rm -f "$GITHUB_TOKEN_SKIP"

# --- a rate-limited build explains itself ---------------------------------------
fake_nix() { echo "error: unable to download 'https://api.github.com/repos/NixOS/nixpkgs/commits/x': HTTP error 403"; echo '{"message":"API rate limit exceeded for 185.15.129.9."}'; return 1; }
out="$(run_builder base fake_nix 2>&1)" && fail "run_builder must keep the failure status"
assert_contains "$out" "API rate limit exceeded for" "the original error is still shown"
assert_contains "$out" "github-token" "points at the fix"
assert_contains "$out" "$GITHUB_TOKEN_URL" "with the link"
out="$(run_builder project fake_nix 2>&1)" || true
assert_contains "$out" "never get your token" "project builds explain why the token doesn't help"
save_github_token "ghp_stored123" >/dev/null 2>&1
fake_401() { echo "error: HTTP error 401"; echo '{"message":"Bad credentials"}'; return 1; }
out="$(run_builder base fake_401 2>&1)" || true
assert_contains "$out" "expired" "an expired token is diagnosed"
ok_cmd() { echo fine; }
assert_eq "$(run_builder base ok_cmd 2>&1)" "fine" "success is passed through untouched"

# --- wiring ----------------------------------------------------------------------
body="$(cat "$REPO_DIR/nixenv.sh")"
for fn in cmd_build cmd_update; do
  f="$(printf '%s' "$body" | sed -n "/^$fn()/,/^}/p" | code_only)"
  assert_contains "$f" "ensure_github_token" "$fn asks when missing"
  assert_contains "$f" "run_builder base" "$fn explains rate limits"
done
assert_contains "$("$REPO_DIR/nixenv.sh" --help)" "github-token" "documented in --help"
rm -f "$GITHUB_TOKEN_FILE"
true
