#!/usr/bin/env bash
# The generated entrypoint contains every feature hook, with correct quoting.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$CONTEXT_DIR"; materialize_context
ep="$(cat "$CONTEXT_DIR/entrypoint.sh")"
sh -n "$CONTEXT_DIR/entrypoint.sh" || fail "entrypoint parses"

# custom app mount honoured everywhere
assert_contains "$ep" 'APP_MOUNT="${NIXENV_APP_MOUNT:-/app}"'
assert_contains "$ep" '$APP_MOUNT/.nixenv/sv' "service discovery uses APP_MOUNT"

# /etc/hosts rebuild: guard + both extra sources + hostname line
assert_contains "$ep" '[ -w /etc/hosts ]'
assert_contains "$ep" 'NIXENV_EXTRA_PROFILE/etc/hosts.extra' "flake-declared hosts"
assert_contains "$ep" '/etc/hosts.extra' "host-side hosts"
assert_contains "$ep" '127.0.1.1'

# egress: exported for services AND written to .zshenv; ssh ProxyCommand block
assert_contains "$ep" 'NIXENV_EGRESS_PROXY'
assert_contains "$ep" 'export HTTP_PROXY='
assert_contains "$ep" '# nixenv-egress'
assert_contains "$ep" 'ProxyCommand $PROFILE/bin/socat - PROXY:'

# services: every dir in SVROOT supervised, sshd excluded, absolute runsv
assert_contains "$ep" 'for d in "$SVROOT"/*/'
assert_contains "$ep" '[ "$sname" = "sshd" ] && continue'
assert_contains "$ep" 'exec "$RUNSV" "$SVROOT/sshd"'

# startup hooks: all three sources sourced, function called, failures tolerated
assert_contains "$ep" 'etc/nixenv-hooks.sh' "flake-declared hook path"
assert_contains "$ep" '$APP_MOUNT/.nixenv/hooks.sh' "repo hook path"
assert_contains "$ep" '.nixenv-hooks.sh' "home hook path"
assert_contains "$ep" 'command -v nixenv_pre_ssh_start' "hook presence check"
assert_contains "$ep" 'nixenv_pre_ssh_start || echo' "hook failure tolerated"
# Ordering matters: PATH (so hooks can call project-flake binaries like a
# <project>-setup script) → hook (so it can add services) → supervise scan.
path_line="$(printf '%s\n' "$ep" | grep -n 'export PATH="${_extra}' | cut -d: -f1)"
hook_line="$(printf '%s\n' "$ep" | grep -n 'command -v nixenv_pre_ssh_start' | cut -d: -f1)"
scan_line="$(printf '%s\n' "$ep" | grep -n 'for d in "\$SVROOT"/\*/' | cut -d: -f1)"
[ "$path_line" -lt "$hook_line" ] || fail "PATH must be exported before hooks run"
[ "$hook_line" -lt "$scan_line" ] || fail "hook must run before the service scan"

# open ssh: empty password + loopback-only is host-side; config flags here
assert_contains "$ep" 'PermitEmptyPasswords yes'
assert_contains "$ep" 'PermitRootLogin no'
assert_contains "$ep" 'AcceptEnv LANG LC_* ZMX_SESSION'

# zshrc: PATH layering keeps project profile first; cd to app mount
zshrc="$(cat "$CONTEXT_DIR/home-skel/.zshrc")"
assert_contains "$zshrc" 'NIXENV_EXTRA_PROFILE/bin:' "project profile ahead of base"
assert_contains "$zshrc" 'NIXENV_APP_MOUNT' "login cd uses app mount"

# gitconfig: modern defaults present, identity/credentials via includes
gc="$(cat "$CONTEXT_DIR/home-skel/.gitconfig")"
for k in 'algorithm = histogram' 'autoSetupRemote = true' 'defaultBranch = main' \
         'excludesfile = ~/.gitignore' 'path = ~/.gitconfig.identity'; do
  assert_contains "$gc" "$k"
done

# nvim: AstroNvim v6 + OSC52 clipboard
nvim="$(cat "$CONTEXT_DIR/home-skel/.config/nvim/init.lua")"
assert_contains "$nvim" 'version = "^6"'
assert_contains "$nvim" 'osc52'
