#!/usr/bin/env bash
# 'deploy': names, the separate deploy allowlist in squid (and that it does not
# leak into the dev project's), the ssh argv, the deploy entrypoint, and what
# the deploy container mounts.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# ── names ────────────────────────────────────────────────────────────────────
assert_eq "$(deploy_container_name alpha)" "nxt__alpha-deploy" "deploy container name"
assert_eq "$(deploy_net alpha)" "nxt__alpha-deploy" "deploy network name"
[ "$(deploy_container_name alpha)" != "$(container_name alpha)" ] || fail "deploy container differs from the project's"
# 'stop' with no project sweeps ^<prefix>(-|__) — the deploy container included.
printf '%s\n' "$(deploy_container_name alpha)" | grep -qE "^${CONTAINER_PREFIX}(-|__)" \
  || fail "stop-all pattern catches the deploy container"

# ── deploy_hosts: normalised, comments/blank/invalid dropped ─────────────────
rm -rf "$PROJECTS_DIR" "$PROXY_DIR"
mkdir -p "$PROJECTS_DIR/alpha" "$PROJECTS_DIR/open"
printf '5.196.77.220\n# prod\n\n*.example.com\nhttps://bad.example/\n51.255.65.147 # second\n' \
  > "$PROJECTS_DIR/alpha/deploy_hosts"
assert_eq "$(deploy_hosts alpha | tr '\n' ' ')" "5.196.77.220 .example.com 51.255.65.147 " "deploy_hosts normalised"
assert_eq "$(deploy_hosts open)" "" "no deploy_hosts file → empty"
ln -s "$PROJECTS_DIR/alpha/deploy_hosts" "$PROJECTS_DIR/open/deploy_hosts"
assert_eq "$(deploy_hosts open)" "" "a symlinked deploy_hosts is ignored"
rm -f "$PROJECTS_DIR/open/deploy_hosts"

# ── squid: a separate allowlist keyed by the deploy net ──────────────────────
ENGINE=docker
ensure_internal_net() { :; }
ensure_deploy_net()   { :; }
net_subnet() { case "$1" in *-deploy) echo "172.31.5.0/24";; *) echo "172.30.9.0/24";; esac; }
container_running() { return 1; }

printf 'github.com\n' > "$PROJECTS_DIR/alpha/allowed_hosts"
echo 23456 > "$PROJECTS_DIR/alpha/port"
touch "$PROJECTS_DIR/open/unrestricted"; echo 21111 > "$PROJECTS_DIR/open/port"

write_egress_configs
conf="$(cat "$PROXY_DIR/egress/squid.conf")"
assert_contains "$EGRESS_DEPLOYS" "alpha" "alpha has a deploy allowlist"
assert_contains "$conf" "acl deploysrc_alpha src 172.31.5.0/24"
# dev allowlist FIRST, then the deploy-only hosts
assert_contains "$conf" "acl deploydst_alpha dstdomain -n github.com 5.196.77.220 .example.com 51.255.65.147"
assert_contains "$conf" "acl nixenv_projects src 172.30.9.0/24 172.31.5.0/24" "deploy subnet is a known source"
assert_not_contains "$(grep '^acl d_alpha' "$PROXY_DIR/egress/squid.conf")" "5.196.77.220" \
  "deploy hosts stay out of the dev allowlist"

SIM="$TESTS_DIR/squid_acl_sim.py"
cf="$PROXY_DIR/egress/squid.conf"
sim() { python3 "$SIM" "$cf" "$@"; }
DEV=172.30.9.5 DEP=172.31.5.7
assert_eq "$(sim $DEP CONNECT 5.196.77.220 22)"   "allow dns=no" "deploy: ssh to a deploy host"
assert_eq "$(sim $DEP CONNECT api.example.com 443)" "allow dns=yes" "deploy: subdomain entry"
assert_eq "$(sim $DEP CONNECT github.com 443)"    "allow dns=yes" "deploy: dev allowlist applies too"
assert_eq "$(sim $DEP CONNECT github.com 22)"     "allow dns=yes" "deploy: push over ssh to a dev host"
assert_eq "$(sim $DEP CONNECT leak.attacker.example 443)" "deny dns=no" "deploy: unknown name not resolved"
assert_eq "$(sim $DEV CONNECT 5.196.77.220 22)"   "deny dns=no"  "dev: production unreachable"
assert_eq "$(sim $DEV CONNECT github.com 443)"    "allow dns=yes" "dev: own allowlist unchanged"
assert_eq "$(sim $DEP CONNECT 5.196.77.220 25)"   "deny dns=no"  "deploy: Connect_ports still apply"

# An UNRESTRICTED project can still have a deploy allowlist: squid is needed
# for it alone.
rm -f "$PROJECTS_DIR/alpha/deploy_hosts"; touch "$PROJECTS_DIR/alpha/unrestricted"
printf 'deploy.example.org\n' > "$PROJECTS_DIR/open/deploy_hosts"
write_egress_configs
assert_eq "$EGRESS_PROJECTS" "" "no restricted project"
assert_contains "$EGRESS_DEPLOYS" "open"
assert_file "$PROXY_DIR/egress/squid.conf" "squid.conf written for a deploy allowlist alone"
assert_contains "$(cat "$cf")" "acl deploydst_open dstdomain -n deploy.example.org"
rm -f "$PROJECTS_DIR/alpha/unrestricted"

# ── deploy_allow ─────────────────────────────────────────────────────────────
resolve_engine() { return 1; }
rm -f "$PROJECTS_DIR/alpha/deploy_hosts"
out="$(deploy_allow alpha 5.196.77.220 '*.ovh.example' 2>&1)" || fail "deploy_allow succeeds"
assert_eq "$(cat "$PROJECTS_DIR/alpha/deploy_hosts" | tr '\n' ' ')" "5.196.77.220 .ovh.example " "hosts stored, normalised"
out="$(deploy_allow alpha 5.196.77.220 2>&1)"
assert_contains "$out" "already allowed" "deduplicated"
assert_eq "$(grep -c . "$PROJECTS_DIR/alpha/deploy_hosts")" "2" "no duplicate line"
( deploy_allow alpha 'https://x.example/' >/dev/null 2>&1 ) && fail "a URL is rejected"
( deploy_allow alpha 'host:22' >/dev/null 2>&1 ) && fail "a port is rejected"
out="$(deploy_allow alpha github.com 2>&1)"
assert_contains "$out" "deploy can already reach it" "a dev-allowlisted host is not duplicated"
grep -qx github.com "$PROJECTS_DIR/alpha/deploy_hosts" && fail "dev host not copied into deploy_hosts"
assert_eq "$(deploy_allowlist alpha | tr '\n' ' ')" "github.com 5.196.77.220 .ovh.example " "allowlist = dev + deploy, deduplicated"
out="$(cmd_deploy alpha hosts 2>&1)"
assert_contains "$out" "5.196.77.220"; assert_contains "$out" "github.com" "hosts lists both sources"
ln -sf /etc/hostname "$PROJECTS_DIR/open/deploy_hosts"
( deploy_allow open a.example >/dev/null 2>&1 ) && fail "refuses a symlinked deploy_hosts"
rm -f "$PROJECTS_DIR/open/deploy_hosts"

# ── ssh argv ─────────────────────────────────────────────────────────────────
ENGINE=podman
deploy_ssh_argv alpha nxt__alpha-deploy "/Users/me/Library/Group Containers/agent.sock"
argv="${DEPLOY_SSH[*]}"
assert_contains "$argv" "-F /dev/null" "user ssh config ignored"
assert_contains "$argv" "ControlMaster=no" "no shared master connection"
assert_contains "$argv" "ControlPath=none"
assert_contains "$argv" "StrictHostKeyChecking=yes"
assert_contains "$argv" "HostKeyAlias=nixenv-alpha" "same pinned host key as the project"
assert_contains "$argv" "ProxyCommand=podman exec -i nxt__alpha-deploy $PROFILE/bin/socat - TCP:127.0.0.1:$SSHD_PORT" \
  "transport is engine exec, not a published port"
assert_contains "$argv" 'ForwardAgent="/Users/me/Library/Group Containers/agent.sock"' "socket path quoted for ssh"
found=0; for a in "${DEPLOY_SSH[@]}"; do
  [ "$a" = 'ForwardAgent="/Users/me/Library/Group Containers/agent.sock"' ] && found=1
done
assert_eq "$found" 1 "the agent option is ONE argv entry"
deploy_ssh_argv alpha nxt__alpha-deploy yes
assert_contains "${DEPLOY_SSH[*]}" "ForwardAgent=yes"
ENGINE=docker

# ── deploy container: mounts ─────────────────────────────────────────────────
src="$(declare -f deploy_open | code_only)"
assert_contains "$src" '-v "$appv":"$appmnt" ' "app volume mounted read-write (releases commit there)"
assert_not_contains "$src" '"$appmnt":ro' "not read-only any more"
# git identity + credentials: the HOST seed's files, shared (bind-mounted), not copied
assert_contains "$src" '"$pdir/home/.gitconfig.identity:/home/$APP_USER/.gitconfig.identity:ro"'
assert_contains "$src" '"$pdir/home/.gitconfig.credentials:/home/$APP_USER/.gitconfig.credentials:ro"'
assert_contains "$src" '"$pdir/home/.git-credentials:/home/$APP_USER/.git-credentials")' "credentials rw (store helper rewrites)"
assert_contains "$src" '"$pdir/deploy_known_hosts:/etc/nixenv/known_hosts"' "known_hosts persists on the host"
# same tools as the dev container: the project profile, always (no flag)
assert_contains "$src" 'NIXENV_EXTRA_PROFILE="$(project_profile "$name")"' "project profile passed"
assert_not_contains "$src" "withprof" "no --profile option"
assert_contains "$src" '--tmpfs "/home/$APP_USER' "home is a tmpfs"
assert_contains "$src" 'deploy_net "$name"' "own network"
assert_contains "$src" '"$DEPLOY_ENTRYPOINT_FILE"' "deploy entrypoint, not the project one"
assert_contains "$src" "container_hardening_args" "same hardening as project containers"
for bad in home_volume db_volume claude_profile_dir CLAUDE_DIR ENTRYPOINT_FILE:/ extra-parameters project_extra_args '-p '; do
  assert_not_contains "$src" "$bad" "deploy container does not use: $bad"
done
assert_contains "$src" "trap " "removed on exit"

# Deploy settings travel; import re-validates the hosts and gates the configs
# (unit 27 covers the import side).
for f in deploy_hosts deploy_ssh_config deploy_gitconfig deploy_known_hosts; do
  exports_path "$f" || fail "$f should travel with an export"
done

# ── deploy entrypoint ────────────────────────────────────────────────────────
materialize_context
dep="$CONTEXT_DIR/deploy-entrypoint.sh"
assert_file "$dep"
sh -n "$dep" || fail "deploy-entrypoint.sh parses"
body="$(code_only < "$dep")"
assert_contains "$body" "ListenAddress 127.0.0.1" "sshd on loopback only"
assert_contains "$body" "AllowAgentForwarding yes"
assert_contains "$body" "AllowTcpForwarding no"
assert_contains "$body" "PermitUserRC no"
assert_contains "$body" "AuthorizedKeysFile /etc/nixenv/authorized_keys" "host-generated keys only"
assert_contains "$body" "GIT_CONFIG_KEY_0=core.fsmonitor" "git: no fsmonitor from the repo"
assert_contains "$body" "core.hooksPath" "git: no hooks from the repo"
assert_contains "$body" "StrictHostKeyChecking accept-new" "TOFU into the host-side known_hosts"
assert_contains "$body" "/etc/nixenv/deploy_gitconfig" "deploy_gitconfig included"
assert_not_contains "$body" "cp /etc/nixenv/git" "git files are shared, not copied"
for bad in hooks.sh nixenv-hooks.sh "/sv/" runsv .nixenv/sv nixenv_pre_ssh_start; do
  assert_not_contains "$body" "$bad" "deploy entrypoint runs nothing from the repo: $bad"
done
# Same PATH rule as the project entrypoint: ~/.local/bin first.
# (not `grep | while`: fail would only exit the pipeline's subshell)
bad_path="$(grep 'export PATH=' "$dep" | grep -v 'PATH="\\$HOME/.local/bin:' || true)"
assert_eq "$bad_path" "" "every PATH export puts ~/.local/bin first"
[ -n "$(grep 'export PATH=' "$dep")" ] || fail "deploy entrypoint sets PATH"

# age + sops are in the base toolbox (Go binaries: no runtime on PATH).
pkgs="$(sed 's/[[:space:]]*#.*//' "$CONTEXT_DIR/flake.nix")"
printf '%s\n' "$pkgs" | grep -qE '^[[:space:]]+age$'  || fail "base flake ships age"
printf '%s\n' "$pkgs" | grep -qE '^[[:space:]]+sops$' || fail "base flake ships sops"

# The name lands in ssh's ProxyCommand (run by a shell): strict charset.
mkdir -p "$PROJECTS_DIR/x;id"
( cmd_deploy 'x;id' hosts >/dev/null 2>&1 ) && fail "a project name with ';' is refused"
rm -rf "$PROJECTS_DIR/x;id"

# usage documents it
assert_contains "$(usage)" "deploy <project>"
echo "ok"
