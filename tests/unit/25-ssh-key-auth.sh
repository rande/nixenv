#!/usr/bin/env bash
# Ssh into a project is KEY-ONLY. sshd listens on every interface in the
# container, so other projects can reach it (nixenv_net, proxy relays). The only
# key it accepts is generated on the host and mounted read-only.
source "$(dirname "$0")/../lib.sh"
source_nixenv

have ssh-keygen || skip "ssh-keygen not available on this machine"

body="$(cat "$REPO_DIR/nixenv.sh")"
rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/demo"
pdir="$PROJECTS_DIR/demo"; sd="$pdir/ssh"

# --- no usable password for anyone ---------------------------------------------
write_passwd_files "$pdir"
assert_contains "$(cat "$pdir/shadow")" "$APP_USER:*:" "app has no usable password"
assert_not_contains "$(cat "$pdir/shadow")" "$APP_USER::" "app's password is not empty"
# '!' would LOCK the account and OpenSSH then refuses even pubkey logins.
assert_not_contains "$(cat "$pdir/shadow")" "$APP_USER:!" "app is not locked (pubkey must work)"

# --- the per-project key --------------------------------------------------------
ensure_project_ssh_key "$pdir" >/dev/null 2>&1 || fail "ensure_project_ssh_key failed"
assert_file "$sd/id_ed25519"     "private key generated"
assert_file "$sd/id_ed25519.pub" "public key generated"
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
assert_eq "$(perm "$sd/id_ed25519")" "600" "private key is 600"
assert_eq "$(perm "$sd")"            "700" "ssh dir is 700"
assert_eq "$(cat "$sd/authorized_keys")" "$(cat "$sd/id_ed25519.pub")" "authorized_keys = the project key"

# Idempotent: the key is never silently rotated (it would lock the user out of
# a running container, whose mount still holds the old authorized_keys).
before="$(cat "$sd/id_ed25519.pub")"
ensure_project_ssh_key "$pdir" >/dev/null 2>&1
assert_eq "$(cat "$sd/id_ed25519.pub")" "$before" "key is not regenerated"

# authorized_keys.extra: your own keys, comments and blanks stripped.
printf '# my laptop key\n\nssh-ed25519 AAAAEXTRA me@laptop\n' > "$sd/authorized_keys.extra"
ino_before="$(ls -i "$sd/authorized_keys" | awk '{print $1}')"
ensure_project_ssh_key "$pdir" >/dev/null 2>&1
ak="$(cat "$sd/authorized_keys")"
assert_contains "$ak" "$before"                      "project key still first"
assert_contains "$ak" "ssh-ed25519 AAAAEXTRA me@laptop" "extra key appended"
assert_not_contains "$ak" "#"                         "comments stripped"
assert_eq "$(printf '%s\n' "$ak" | grep -c '^$')" "0" "blank lines stripped"
# Rewritten IN PLACE: a running container's bind mount keeps pointing at the
# same inode, so an added key works without a restart.
ino_after="$(ls -i "$sd/authorized_keys" | awk '{print $1}')"
assert_eq "$ino_after" "$ino_before" "authorized_keys rewritten in place (same inode)"

# --- host ssh config ------------------------------------------------------------
project_port() { echo 23456; }
write_host_ssh_config demo >/dev/null 2>&1
cfg="$(cat "$sd/config")"
assert_contains "$cfg" "IdentityFile \"$sd/id_ed25519\"" "new config uses the project key"
assert_contains "$cfg" "IdentitiesOnly yes"             "and only that key"

# Migration: a config written before key-only auth gains the lines once, after User,
# with hand edits preserved.
cat > "$sd/config" <<EOF
# hand-edited
Host demo demo.*
    HostName 127.0.0.1
    Port 23456
    User $APP_USER
    RemoteCommand my-custom-thing
EOF
write_host_ssh_config demo >/dev/null 2>&1
cfg="$(cat "$sd/config")"
assert_contains "$cfg" "IdentityFile"          "old config migrated"
assert_contains "$cfg" "RemoteCommand my-custom-thing" "hand edits kept"
assert_contains "$cfg" "# hand-edited"          "comments kept"
user_ln="$(grep -n "User $APP_USER" "$sd/config" | cut -d: -f1)"
id_ln="$(grep -n 'IdentityFile' "$sd/config" | cut -d: -f1)"
assert_eq "$id_ln" "$((user_ln + 1))" "IdentityFile inserted right after User"
write_host_ssh_config demo >/dev/null 2>&1
assert_eq "$(grep -c IdentityFile "$sd/config")" "1" "migration is idempotent"

# --- wiring --------------------------------------------------------------------
run_fn="$(printf '%s' "$body" | sed -n '/^cmd_run()/,/^}/p' | code_only)"
assert_contains "$run_fn" '-v "$pdir/ssh/authorized_keys":/etc/nixenv/authorized_keys:ro' \
  "run mounts authorized_keys read-only"
assert_contains "$run_fn" 'ensure_project_ssh_key "$pdir"' "run ensures the key exists"
# The key must exist BEFORE the ssh config is (re)written, which points at it.
k_ln="$(printf '%s\n' "$run_fn" | grep -n 'ensure_project_ssh_key' | head -1 | cut -d: -f1)"
c_ln="$(printf '%s\n' "$run_fn" | grep -n 'write_host_ssh_config' | head -1 | cut -d: -f1)"
[ "$k_ln" -lt "$c_ln" ] || fail "key must be generated before the ssh config"
assert_contains "$run_fn" 'started before key-only ssh' "warns about pre-key-auth containers"

ssh_fn="$(printf '%s' "$body" | sed -n '/^cmd_ssh()/,/^}/p' | code_only)"
assert_contains "$ssh_fn" '-i "$pdir/ssh/id_ed25519"' "nixenv ssh uses the project key"
assert_contains "$ssh_fn" 'IdentitiesOnly=yes'        "and only that key"

# The key must never travel in an export.
# (not even with --with-home: it is re-created on import)
for f in ssh/id_ed25519 ssh/id_ed25519.pub ssh/authorized_keys ssh/config ssh/known_hosts; do
  exports_path "$f" 1 && fail "$f must not travel in an export"
done
# your OWN extra keys do travel (import applies them only after a yes)
exports_path ssh/authorized_keys.extra || fail "ssh/authorized_keys.extra should travel"
true
