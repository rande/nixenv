#!/usr/bin/env bash
# Each project gets its own ~/.claude and ~/.claude.json; only the login
# (.credentials.json) is shared. A hook/MCP server planted by one project must
# not reach another.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$CLAUDE_DIR"
prepare_claude_profile alpha
prepare_claude_profile beta
pa="$(claude_profile_dir alpha)"; pb="$(claude_profile_dir beta)"

assert_file "$CLAUDE_DIR/.credentials.json"     "shared login file exists before mounting"
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
assert_eq "$(perm "$CLAUDE_DIR/.credentials.json")" "600" "credentials are 600"
assert_file "$pa/claude.json"                   "per-project .claude.json"
assert_file "$pa/dot-claude/.credentials.json"  "mount point pre-created as a FILE"
[ -d "$pa/dot-claude/projects" ] || fail "projects mount point pre-created"
[ -d "$CLAUDE_DIR/projects/nixenv-alpha" ] || fail "transcripts dir kept"
assert_contains "$(cat "$pa/claude.json")" "hasCompletedOnboarding" "no re-onboarding"

# A write in alpha's profile is invisible to beta's.
echo '{"hooks":{"PreToolUse":[{"command":"curl evil"}]}}' > "$pa/dot-claude/settings.json"
echo '{"mcpServers":{"evil":{}}}' > "$pa/claude.json"
[ -e "$pb/dot-claude/settings.json" ] && fail "alpha's settings leaked into beta"
assert_not_contains "$(cat "$pb/claude.json")" "mcpServers" "alpha's MCP server leaked into beta"

# A fresh profile never inherits the old fully-shared config.
echo '{"mcpServers":{"planted":{}}}' > "$CLAUDE_JSON"
prepare_claude_profile gamma
assert_not_contains "$(cat "$(claude_profile_dir gamma)/claude.json")" "planted" \
  "new profiles are not seeded from the legacy shared config"
# Idempotent: an existing profile is left alone.
prepare_claude_profile alpha
assert_contains "$(cat "$pa/claude.json")" "mcpServers" "existing profile untouched"

# --- cmd_run wiring --------------------------------------------------------------
body="$(cat "$REPO_DIR/nixenv.sh")"
run_fn="$(printf '%s' "$body" | sed -n '/^cmd_run()/,/^}/p' | code_only)"
assert_contains "$run_fn" '-v "$cprof/dot-claude":/home/"$APP_USER"/.claude ' "per-project ~/.claude"
assert_contains "$run_fn" '-v "$cprof/claude.json":/home/"$APP_USER"/.claude.json' "per-project ~/.claude.json"
assert_contains "$run_fn" '-v "$CLAUDE_DIR/.credentials.json":/home/"$APP_USER"/.claude/.credentials.json' \
  "only the credentials file is shared"
assert_not_contains "$run_fn" '-v "$CLAUDE_DIR":' "the whole shared dir is no longer mounted"
assert_not_contains "$run_fn" '$CLAUDE_JSON' "the shared .claude.json is no longer mounted"
del_fn="$(printf '%s' "$body" | sed -n '/^cmd_delete()/,/^}/p' | code_only)"
assert_contains "$del_fn" 'rm -rf "$(claude_profile_dir "$name")"' "delete drops the profile"
true
