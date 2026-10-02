#!/usr/bin/env bash
# 'deploy': a throwaway container with the agent forwarded over an ssh session
# carried by '<engine> exec', the shared app volume, the seed's git files
# shared in, a tmpfs home, allowed_hosts + deploy_hosts, nothing left on exit.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
require_store_bin socat
command -v ssh >/dev/null 2>&1 || skip "ssh client not installed"

mkproj dp
nx run dp >/dev/null
nx stop dp >/dev/null
dexec_vol() { involume nxt_dp_app "$1"; }
dexec_vol 'echo marker > /v/MARKER'

# Git credentials in the host seed are SHARED into the deploy home (not copied).
printf 'https://u:tok@git.example\n' > "$NIXENV_PROJECTS_DIR/dp/home/.git-credentials"
chmod 600 "$NIXENV_PROJECTS_DIR/dp/home/.git-credentials"

# ── a one-shot command: identity, shared code, tmpfs home, base PATH ─────────
out="$(nx deploy dp --no-agent -- 'echo USER=$(id -un); cat MARKER; echo from-deploy > FROM_DEPLOY && echo CODE=rw || echo CODE=ro; df -P $HOME | tail -1; echo PATH=$PATH; echo DEPLOY=$NIXENV_DEPLOY; command -v sops age; cat ~/.git-credentials; echo https://u:new@git.example >> ~/.git-credentials' 2>&1)" \
  || fail "deploy command failed: $out"
assert_contains "$out" "USER=app" "logs in as app"
assert_contains "$out" "marker" "sees the app volume"
assert_contains "$out" "CODE=rw" "app volume is writable"
assert_contains "$(involume nxt_dp_app 'cat /v/FROM_DEPLOY')" "from-deploy" "edits land in the shared app volume"
assert_contains "$out" "u:tok@git.example" "seed git credentials visible"
grep -q 'u:new@git.example' "$NIXENV_PROJECTS_DIR/dp/home/.git-credentials" \
  || fail "credential updates go back to the host seed (shared file)"
assert_contains "$out" "tmpfs" "home is a tmpfs"
assert_contains "$out" "DEPLOY=1"
assert_contains "$out" "/bin/sops" "sops available"
assert_contains "$out" "/bin/age" "age available"
"$E" ps -a --format '{{.Names}}' | grep -qx nxt__dp-deploy && fail "deploy container left behind"

# ── the agent rides the session ──────────────────────────────────────────────
if command -v ssh-agent >/dev/null 2>&1 && command -v ssh-add >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" >/dev/null
  k="$NIXTEST_HOME/agentkey"; ssh-keygen -q -t ed25519 -N '' -C deploy-agent-test -f "$k"
  ssh-add "$k" 2>/dev/null
  out="$(nx deploy dp -- 'ssh-add -l' 2>&1)" || true
  ssh-agent -k >/dev/null 2>&1 || true
  assert_contains "$out" "deploy-agent-test" "forwarded agent visible in the deploy container"
else
  note "no ssh-agent on this host — agent forwarding not checked"
fi

# The dev container never gets an agent socket from any of this.
nx run dp >/dev/null
out="$(dexec dp sh -c 'ls /tmp/ssh-* 2>/dev/null; echo END')"
assert_eq "$out" "END" "no agent socket in the dev container"
nx stop dp >/dev/null

# ── egress: allowed_hosts + deploy_hosts; nothing else ───────────────────────
nx allow dp dev-only.example >/dev/null
nx deploy dp allow deploy-only.example >/dev/null
out="$(nx deploy dp --no-agent -- 'curl -s -o /dev/null -w "%{http_code}" -x "$HTTPS_PROXY" http://elsewhere.example/' 2>/dev/null || true)"
assert_eq "$out" "403" "squid refuses a host in neither list"
grep -q 'deploydst_dp dstdomain -n dev-only.example deploy-only.example' "$PROXY_DIR/egress/squid.conf" \
  || fail "deploy ACL = dev allowlist + deploy hosts"
grep '^acl d_dp ' "$PROXY_DIR/egress/squid.conf" | grep -q deploy-only.example \
  && fail "deploy host leaked into the dev allowlist"

# No allowlist → no network at all (and the session still works).
rm -f "$NIXENV_PROJECTS_DIR/dp/deploy_hosts"
out="$(nx deploy dp --no-agent -- 'getent hosts nxt-egress >/dev/null && echo NET || echo NONET' 2>/dev/null)"
assert_contains "$out" "NONET" "no deploy hosts → no route to the egress proxy"

# A leftover container is refused, then removed by 'stop'.
"$E" run -d --name nxt__dp-deploy debian:stable-slim sleep 60 >/dev/null
nx deploy dp --no-agent -- true >/dev/null 2>&1 && fail "a second session must be refused"
nx deploy dp stop >/dev/null
"$E" ps -a --format '{{.Names}}' | grep -qx nxt__dp-deploy && fail "'deploy stop' removes it"
echo ok
