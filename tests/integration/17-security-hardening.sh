#!/usr/bin/env bash
# Security hardening end to end: hardened runtime flags, per-project Claude state,
# and a pinned host key that `ssh <project>` verifies.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
command -v ssh >/dev/null 2>&1 || skip "host ssh client not installed"

mkproj a --unrestricted
mkproj b --unrestricted
nx run a >/dev/null
nx run b >/dev/null
sleep 2

# --- Capabilities, no-new-privileges, pids limit ------------------------
assert_contains "$("$E" inspect -f '{{.HostConfig.CapDrop}}' nxt-a)" "ALL" "CapDrop ALL"
assert_contains "$("$E" inspect -f '{{.HostConfig.SecurityOpt}}' nxt-a)" "no-new-privileges" "no-new-privileges"
assert_contains "$("$E" inspect -f '{{.HostConfig.PidsLimit}}' nxt-a)" "4096" "pids limit"
# It still works without any capability: the loopback relay binds port 443.
dexec a "$PROFILE_PATH/bin/zsh" -lc 'test -d "$HOME/.nixenv-sv/proxy-relay-443"' \
  || fail "the low-port relay service is missing"

# --- A Claude hook planted in A is not visible in B ---------------------
dexec a sh -c 'echo "{\"hooks\":{\"x\":1}}" > "$HOME/.claude/settings.json"; echo "{\"mcpServers\":{\"evil\":{}}}" > "$HOME/.claude.json"'
dexec b sh -c 'test ! -e "$HOME/.claude/settings.json"' || fail "A's Claude settings are visible in B"
dexec b sh -c '! grep -q mcpServers "$HOME/.claude.json"' || fail "A's MCP servers are visible in B"
# The login IS shared.
dexec a sh -c 'echo "{\"token\":\"shared\"}" > "$HOME/.claude/.credentials.json"'
dexec b sh -c 'grep -q shared "$HOME/.claude/.credentials.json"' || fail "the login is not shared"

# --- The generated ssh config verifies the host key ---------------------
cfg="$PROJECTS_DIR/a/ssh/config"
out="$(ssh -F "$cfg" -o BatchMode=yes -o RemoteCommand=none -o RequestTTY=no \
          -o ControlMaster=no a 'echo PINNED-OK' 2>&1)" || fail "pinned ssh failed: $out"
assert_contains "$out" "PINNED-OK" "ssh with the pinned host key"
# B's host key under A's alias → mismatch → refused.
port_b="$(cat "$PROJECTS_DIR/b/port")"
out="$(ssh -F "$cfg" -o BatchMode=yes -o RemoteCommand=none -o RequestTTY=no \
          -o ControlMaster=no -o Port="$port_b" a true 2>&1 || true)"
assert_contains "$out" "HOST IDENTIFICATION HAS CHANGED" "a different sshd on the port is refused"
true
