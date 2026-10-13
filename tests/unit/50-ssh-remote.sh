#!/usr/bin/env bash
# ssh from another machine (SSH-04): the laptop block is generic; the port and
# the pinned host key are answered here, on stdout only, without writing the
# context; --remote makes projects accept the host's plain login keys only.
source "$(dirname "$0")/../lib.sh"
source_nixenv
have ssh-keygen || skip "ssh-keygen not available on this machine"

rm -rf "$PROJECTS_DIR" "$CONTEXT_DIR"; mkdir -p "$PROJECTS_DIR/demo"
pdir="$PROJECTS_DIR/demo"; sd="$pdir/ssh"
echo 23456 > "$pdir/port"
ensure_project_ssh_key "$pdir" >/dev/null 2>&1 || fail "ensure_project_ssh_key failed"

# No engine here: the port is answered as is (the auto-start needs one).
run() { CONTAINER_ENGINE=/nonexistent "$NIXENV_SH" ssh-config "$@"; }
: > "$SSH_REMOTE_FILE"

assert_eq "$(run --port devbox.demo 2>/dev/null)"      "23456" "port for <alias>.<p>"
assert_eq "$(run --port devbox.demo.work 2>/dev/null)" "23456" "port for <alias>.<p>.<session>"
assert_eq "$(run --port '[devbox.demo]:22' 2>/dev/null)" "23456" "port for a bracketed host"
[ -e "$CONTEXT_DIR" ] && fail "--port must not materialise the context (it runs on every connection)"
assert_eq "$(run --known-hosts devbox.demo 2>/dev/null)" \
  "devbox.demo $(cut -d' ' -f1,2 "$sd/host_ed25519_key.pub")" "the pinned host key, under the name ssh looked up"

for bad in 'demo' 'devbox.' 'devbox.x;id' 'devbox.-o' 'devbox.proxy' 'devbox.nope' 'devbox.de mo'; do
  out="$(run --port "$bad" 2>/dev/null)" && fail "--port accepted '$bad'"
  assert_eq "$out" "" "nothing on stdout for '$bad'"
  run --known-hosts "$bad" >/dev/null 2>&1 && fail "--known-hosts accepted '$bad'"
done

# --remote: projects accept this host's PLAIN login keys, nothing restricted.
rm -f "$SSH_REMOTE_FILE" "$NIXTEST_HOME"/lap* "$NIXTEST_HOME"/lim*
ssh-keygen -q -t ed25519 -N '' -C laptop -f "$NIXTEST_HOME/lap" </dev/null
ssh-keygen -q -t ed25519 -N '' -C limited -f "$NIXTEST_HOME/lim" </dev/null
lap="$(cut -d' ' -f2 "$NIXTEST_HOME/lap.pub")"; lim="$(cut -d' ' -f2 "$NIXTEST_HOME/lim.pub")"
{ cat "$NIXTEST_HOME/lap.pub"; printf 'command="rsync --server" %s\n' "$(cat "$NIXTEST_HOME/lim.pub")"; } > "$HOST_AUTHORIZED_KEYS"
run --port devbox.demo >/dev/null 2>&1 && fail "--port must refuse while remote ssh is off"
assert_not_contains "$(cat "$sd/authorized_keys")" "$lap" "host keys are not accepted before --remote"
run --remote=devbox >/dev/null 2>&1 || fail "--remote failed"
assert_file "$SSH_REMOTE_FILE" "--remote turns it on"
assert_contains "$(cat "$sd/authorized_keys")" "$lap" "the host's plain login key is accepted"
assert_not_contains "$(cat "$sd/authorized_keys")" "$lim" "a key restricted on the host is left out"
assert_contains "$(cat "$sd/authorized_keys")" "$(cut -d' ' -f2 "$sd/id_ed25519.pub")" "the project key stays"
assert_eq "$(run --port devbox.demo 2>/dev/null)" "23456" "--port answers once it is on"
# a key added to the host later is picked up by the next connection
ssh-keygen -q -t ed25519 -N '' -C later -f "$NIXTEST_HOME/lap2" </dev/null
cat "$NIXTEST_HOME/lap2.pub" >> "$HOST_AUTHORIZED_KEYS"
run --port devbox.demo >/dev/null 2>&1
assert_contains "$(cat "$sd/authorized_keys")" "$(cut -d' ' -f2 "$NIXTEST_HOME/lap2.pub")" "--port refreshes the keys"
run --remote=off >/dev/null 2>&1 || fail "--remote=off failed"
[ -e "$SSH_REMOTE_FILE" ] && fail "--remote=off must remove the marker"
assert_not_contains "$(cat "$sd/authorized_keys")" "$lap" "--remote=off drops the host keys"
run --remote=devbox >/dev/null 2>&1

# The laptop block: generic, parsed by the real ssh client.
blk="$(run --remote=devbox 2>/dev/null | sed -n '/^# --- nixenv/,$p')"
assert_not_contains "$blk" "23456" "no port in the laptop block"
assert_not_contains "$blk" "demo" "no project in the laptop block"
assert_contains "$blk" "ssh -n devbox" "lookups never read the ProxyCommand's stdin"
run --remote='a;b' >/dev/null 2>&1 && fail "an unsafe alias was accepted"
if have ssh; then
  printf '%s\n' "$blk" > "$NIXTEST_HOME/laptop_config"
  g="$(ssh -F "$NIXTEST_HOME/laptop_config" -G devbox.demo 2>&1)" || fail "ssh can't parse the block: $g"
  assert_contains "$g" "knownhostscommand /bin/sh -c" "host key fetched from the remote"
  assert_contains "$g" "stricthostkeychecking true" "strict host key checking"
  assert_contains "$g" "userknownhostsfile /dev/null" "no local known_hosts to go stale"
  assert_not_contains "$g" "remotecommand" "<alias>.<p> is a plain shell"
  g="$(ssh -F "$NIXTEST_HOME/laptop_config" -G devbox.demo.work 2>&1)"
  assert_contains "$g" "remotecommand $PROFILE/bin/zmx attach devbox.demo.work" "<alias>.<p>.<x> attaches zmx"
  # a local nixenv project of the same name must not capture the remote one
  printf 'Host demo demo.*\n    HostKeyAlias nixenv-demo\n    Port 23456\n\n%s\n' "$blk" > "$NIXTEST_HOME/laptop_config"
  g="$(ssh -F "$NIXTEST_HOME/laptop_config" -G devbox.demo 2>&1)"
  assert_not_contains "$g" "hostkeyalias" "a local project's block does not apply"
  g="$(ssh -F "$NIXTEST_HOME/laptop_config" -G devbox 2>&1)"
  assert_not_contains "$g" "proxycommand" "the jump host itself is not proxied"
fi

# Early dispatch: the plumbing runs before materialize_context.
main_fn="$(sed -n '/^main()/,/^}/p' "$NIXENV_SH" | code_only)"
early="${main_fn%%materialize_context*}"
assert_contains "$early" '--port|--known-hosts) cmd_ssh_config' "plumbing dispatched early"
true
