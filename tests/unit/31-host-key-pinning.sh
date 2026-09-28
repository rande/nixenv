#!/usr/bin/env bash
# The project's sshd host key is generated on the HOST and pinned, so
# `ssh <project>` refuses an impostor squatting the project's port.
source "$(dirname "$0")/../lib.sh"
source_nixenv
have ssh-keygen || skip "ssh-keygen not available on this machine"

rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/demo"
pdir="$PROJECTS_DIR/demo"; sd="$pdir/ssh"
ensure_project_ssh_key "$pdir" >/dev/null 2>&1 || fail "ensure_project_ssh_key failed"
assert_file "$sd/host_ed25519_key" "host key generated on the host"
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
assert_eq "$(perm "$sd/host_ed25519_key")" "600" "host private key is 600"
assert_eq "$(cat "$sd/known_hosts")" "nixenv-demo $(cut -d' ' -f1,2 "$sd/host_ed25519_key.pub")" \
  "known_hosts pins it under the project alias"
before="$(cat "$sd/host_ed25519_key.pub")"
ensure_project_ssh_key "$pdir" >/dev/null 2>&1
assert_eq "$(cat "$sd/host_ed25519_key.pub")" "$before" "host key is stable"

project_port() { echo 23456; }
write_host_ssh_config demo >/dev/null 2>&1
cfg="$(cat "$sd/config")"
assert_not_contains "$cfg" "StrictHostKeyChecking no"   "no blind trust"
assert_not_contains "$cfg" "/dev/null"                  "known hosts are not discarded"
assert_contains "$cfg" "StrictHostKeyChecking yes"      "strict checking"
assert_contains "$cfg" "HostKeyAlias nixenv-demo"       "key tied to the project, not the port"
assert_contains "$cfg" "UserKnownHostsFile \"$sd/known_hosts\"" "per-project known_hosts"

# Migration of an old, unpinned config: only the two generated lines change.
cat > "$sd/config" <<CFG
# hand-edited
Host demo demo.*
    HostName 127.0.0.1
    Port 23456
    User $APP_USER
    IdentityFile "$sd/id_ed25519"
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    RemoteCommand my-thing
CFG
write_host_ssh_config demo >/dev/null 2>&1
cfg="$(cat "$sd/config")"
assert_contains "$cfg" "StrictHostKeyChecking yes" "migrated to strict"
assert_contains "$cfg" "HostKeyAlias nixenv-demo"  "alias added"
assert_contains "$cfg" "UserKnownHostsFile \"$sd/known_hosts\"" "known_hosts added"
assert_contains "$cfg" "RemoteCommand my-thing"    "hand edits kept"
assert_contains "$cfg" "# hand-edited"             "comments kept"
write_host_ssh_config demo >/dev/null 2>&1
assert_eq "$(grep -c HostKeyAlias "$sd/config")" "1" "migration is idempotent"

# --- wiring --------------------------------------------------------------------
body="$(cat "$REPO_DIR/nixenv.sh")"
run_fn="$(printf '%s' "$body" | sed -n '/^cmd_run()/,/^}/p' | code_only)"
assert_contains "$run_fn" '-v "$pdir/ssh/host_ed25519_key":/etc/nixenv/ssh_host_ed25519_key:ro' \
  "run mounts the host key read-only"
ssh_fn="$(printf '%s' "$body" | sed -n '/^cmd_ssh()/,/^}/p' | code_only)"
assert_contains "$ssh_fn" 'StrictHostKeyChecking=yes'  "nixenv ssh checks strictly"
assert_not_contains "$ssh_fn" 'UserKnownHostsFile=/dev/null'            "nixenv ssh keeps known hosts"
rm -rf "$CONTEXT_DIR"; materialize_context
ep="$(cat "$CONTEXT_DIR/entrypoint.sh")"
assert_contains "$ep" 'cp /etc/nixenv/ssh_host_ed25519_key' "entrypoint uses the mounted host key"
assert_contains "$ep" 'chmod 600 "$SSHRUN/ssh_host_ed25519_key"' "as a private copy sshd accepts"
case " $EXPORT_META_FILES " in *" ssh "*|*host_ed25519*) fail "host key must not be exported";; esac

# --- zmx session names survive HostKeyAlias -----------------------------------
# %k expands to the HostKeyAlias when one is set, so `ssh demo.x` would attach
# the session "nixenv-demo" every time. The session must come from %n.
rm -f "$sd/config"; write_host_ssh_config demo >/dev/null 2>&1
assert_contains "$(cat "$sd/config")" "zmx attach %n" "session name is the host as typed"
assert_not_contains "$(cat "$sd/config")" "zmx attach %k" "never the host key alias"
sed -i.bak 's/zmx attach %n/zmx attach %k/' "$sd/config"; rm -f "$sd/config.bak"
printf '    # a hand-written line mentioning %%k stays\n' >> "$sd/config"
write_host_ssh_config demo >/dev/null 2>&1
assert_contains "$(cat "$sd/config")" "zmx attach %n" "configs written with %k are migrated"
assert_contains "$(cat "$sd/config")" "mentioning %k stays" "other lines untouched"
true
