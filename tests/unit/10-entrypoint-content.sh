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

assert_not_contains "$ep" '@proxy' "no @proxy indirection (loopback relay replaces it)"

# loopback relay: curl/libcurl force *.localhost to 127.0.0.1, so make that real
assert_contains "$ep" 'proxy-relay-$_pp' "relay service dirs"
assert_contains "$ep" 'TCP4-LISTEN:$_pp,bind=127.0.0.1,fork,reuseaddr' "relay listener"
assert_contains "$ep" 'sleep 5; exit 0' "waits for the proxy instead of crash-looping"
# the relay must be installed BEFORE the supervise scan picks services up
relay_ln="$(printf '%s\n' "$ep" | grep -n 'proxy-relay-\$_pp' | head -1 | cut -d: -f1)"
scan_ln="$(printf '%s\n' "$ep" | grep -n 'for d in "\$SVROOT"/\*/' | cut -d: -f1)"
[ "$relay_ln" -lt "$scan_ln" ] || fail "relay must be created before the service scan"

# proxy CA merged into a bundle + exported for every major client
assert_contains "$ep" '/etc/nixenv-proxy-ca.crt' "proxy CA mount path"
assert_contains "$ep" '.nixenv-ca-bundle.crt' "merged bundle"
for v in SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE GIT_SSL_CAINFO NODE_EXTRA_CA_CERTS; do
  assert_contains "$ep" "$v" "exports $v"
done

# Claude transcripts: the dir name must follow the project, not an encoded cwd.
# Needed in BOTH places — the container's -e never reaches an ssh/zmx session
# (sshd builds a fresh environment), and .zshenv never reaches runit services.
assert_contains "$ep" 'export CLAUDE_CODE_PROJECT_DIR_NAME="nixenv-${NIXENV_PROJECT:-unknown}"' \
  ".zshenv sets it for ssh/zmx shells"
body="$(cat "$REPO_DIR/nixenv.sh")"
assert_contains "$body" '-e CLAUDE_CODE_PROJECT_DIR_NAME="nixenv-$name" \' \
  "cmd_run sets it for services and docker exec"
# It must agree with the ~/.claude/projects mount, or transcripts land elsewhere.
assert_contains "$body" 'CLAUDE_DIR/projects/nixenv-$name' "matches the transcripts mount"

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
path_line="$(printf '%s\n' "$ep" | grep -n 'export PATH="$HOME/.local/bin:${_extra}' | cut -d: -f1)"
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

# PATH order must be IDENTICAL in all four places that set it, or a tool
# resolves differently in a login shell, a hook, a runit service and `run cmd`.
# Order: ~/.local/bin (user's own) → project profile → base profile.
zshenv_line="$(printf '%s\n' "$ep" | grep 'export PATH=' | grep '_nixenv_extra')"
assert_contains "$zshenv_line" '.local/bin' ".zshenv puts ~/.local/bin on PATH"
assert_contains "$zshrc"       '.local/bin' ".zshrc re-asserts ~/.local/bin"
assert_contains "$ep" 'mkdir -p "$HOME/.local/bin"' "creates it, so pip --user works"
# Every PATH assignment that mentions a profile must list .local/bin BEFORE it.
printf '%s\n%s\n' "$ep" "$zshrc" | python3 -c '
import sys
bad = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("export PATH=") or "PROFILE/bin" not in line:
        continue
    if ".local/bin" not in line:
        bad.append("no ~/.local/bin: " + line)
    elif line.index(".local/bin") > line.index("PROFILE/bin"):
        bad.append("~/.local/bin after the profile: " + line)
if bad:
    print("\n".join(bad)); sys.exit(1)
' || fail "PATH assignments disagree on ~/.local/bin ordering"

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
