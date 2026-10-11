#!/usr/bin/env bash
# TOOL-02: build first, then switch the profile in one step — a failed build
# leaves the previous toolchain in place. Plus the builder's Nix settings.
source "$(dirname "$0")/../lib.sh"
source_nixenv

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/store/new/bin"
# Fake nix / nix-env: `nix build` prints an output path or fails on demand;
# nix-env --set records the switch.
cat > "$T/bin/nix" <<FAKE
#!/bin/sh
[ "\$1" = build ] || exit 2
[ -n "\${FAIL_BUILD:-}" ] && { echo "error: rate limit exceeded" >&2; exit 1; }
echo "$T/store/new"
FAKE
cat > "$T/bin/nix-env" <<FAKE
#!/bin/sh
echo "\$@" > "$T/switched"
FAKE
chmod +x "$T/bin/nix" "$T/bin/nix-env"
script="$(profile_switch_script)"

PATH="$T/bin:$PATH" sh -euc "$script" sh '.#default' "$T/profiles/shared" >/dev/null 2>&1 \
  || fail "a successful build switches the profile"
assert_eq "$(cat "$T/switched")" "--profile $T/profiles/shared --set $T/store/new" "nix-env --set to the build result"

rm -f "$T/switched"
if FAIL_BUILD=1 PATH="$T/bin:$PATH" sh -euc "$script" sh '.#default' "$T/profiles/shared" >/dev/null 2>&1; then
  fail "a failed build must fail"
fi
assert_no_file "$T/switched" "a failed build never touches the profile"

# A ref with shell syntax stays data (positional arg, never spliced into code).
PATH="$T/bin:$PATH" sh -euc "$script" sh '.#x"; touch '"$T"'/pwned; "' "$T/p" >/dev/null 2>&1 || true
assert_no_file "$T/pwned" "the flake ref is never evaluated as shell"

# Both builds use it, and nothing deletes a profile up front any more.
for fn in cmd_build cmd_build_project; do
  body="$(sed -n "/^$fn()/,/^}/p" "$NIXENV_SH" | code_only)"
  assert_contains "$body" 'sh -euc "$(profile_switch_script)" sh' "$fn builds then switches"
  assert_not_contains "$body" 'rm -f "'"'"'"$PROFILE' "$fn: no profile reset"
  assert_not_contains "$body" 'nix profile install' "$fn: no in-place install"
  assert_not_contains "$body" 'nix store optimise' "$fn: auto-optimise-store instead"
done
assert_not_contains "$(sed -n '/^cmd_build()/,/^}/p' "$NIXENV_SH" | code_only)" '--accept-flake-config' \
  "the base flake has no nixConfig to accept"
assert_contains "$(sed -n '/^cmd_build_project()/,/^}/p' "$NIXENV_SH")" 'keep_project_lock "$name"' \
  "a generated project lock is written back"

# Nix settings: incremental optimisation; the token only where something is fetched.
GITHUB_TOKEN="ghp_abcdefghijklmnopqrstuvwxyz0123456789"
assert_contains "$(nix_config_local)" "auto-optimise-store = true" "auto-optimise"
assert_not_contains "$(nix_config_local)" "access-tokens" "local config carries no token"
assert_contains "$(nix_config)" "access-tokens = github.com=" "base builds get the token"
assert_not_contains "$(nix_config_project)" "access-tokens" "project builds never do"
assert_contains "$(nix_config_project)" "accept-flake-config = false" "projects stay untrusted"
for fn in cmd_gc protect_builder_toolchain; do
  assert_not_contains "$(sed -n "/^$fn()/,/^}/p" "$NIXENV_SH")" 'NIX_CONFIG="$(nix_config)"' "$fn fetches nothing: no token"
done
# Base flake: only the Claude CLI may be unfree, and by name (TOOL-08).
base="$(sed -n "/<<'NIXENV_FLAKE'/,/^NIXENV_FLAKE\$/p" "$NIXENV_SH" | code_only)"
assert_not_contains "$base" "allowUnfree = true" "no blanket unfree in the base flake"
assert_contains "$base" '[ "claude-code" ]' "claude-code allowed by name"

upd="$(sed -n '/^cmd_update()/,/^}/p' "$NIXENV_SH")"
assert_contains "$upd" '-v "$NIX_VOLUME":/nix' "update fetches into the store volume, once"
assert_contains "$(sed -n '/^ensure_builder_usable()/,/^}/p' "$NIXENV_SH")" 'ensure_builder_current' \
  "a bumped BUILDER_IMAGE reaches existing volumes"
true
