#!/usr/bin/env bash
# SEC-02: one project must not be able to ssh into another. Before key-only
# auth, `ssh -p 2222 app@nixenv-<other>` from any unrestricted project landed a
# password-less shell in the other one.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store
command -v ssh >/dev/null 2>&1 || skip "host ssh client not installed"

mkproj a --unrestricted
mkproj b --unrestricted
nx run a >/dev/null
nx run b >/dev/null
sleep 2   # sshd comes up under runit

# --- lateral: from A into B, over the shared network ---------------------------
# No key, then A's own key: both must be refused. BatchMode stops any prompt.
out="$(dexec a "$PROFILE_PATH/bin/zsh" -lc 'ssh -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 app@nxt-b true' 2>&1 || true)"
assert_contains "$out" "Permission denied" "A cannot ssh into B without a key"

dexec a "$PROFILE_PATH/bin/zsh" -lc 'ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/planted" </dev/null' >/dev/null 2>&1
out="$(dexec a "$PROFILE_PATH/bin/zsh" -lc 'ssh -p 2222 -i "$HOME/.ssh/planted" -o IdentitiesOnly=yes -o BatchMode=yes \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
          app@nxt-b true' 2>&1 || true)"
assert_contains "$out" "Permission denied" "A's own key does not open B"

# --- self-authorisation: a container cannot make its own key valid -------------
dexec a "$PROFILE_PATH/bin/zsh" -lc 'cat "$HOME/.ssh/planted.pub" >> "$HOME/.ssh/authorized_keys"' >/dev/null 2>&1
out="$(dexec a "$PROFILE_PATH/bin/zsh" -lc 'ssh -p 2222 -i "$HOME/.ssh/planted" -o IdentitiesOnly=yes -o BatchMode=yes \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
          app@127.0.0.1 true' 2>&1 || true)"
assert_contains "$out" "Permission denied" "a key planted in ~/.ssh/authorized_keys is ignored"

# The mounted keys file must be read-only inside the container.
dexec a "$PROFILE_PATH/bin/zsh" -lc 'echo x >> /etc/nixenv/authorized_keys' >/dev/null 2>&1 \
  && fail "the container could write /etc/nixenv/authorized_keys"

# --- the host still gets in, with the project key and no prompt ----------------
port_a="$(cat "$PROJECTS_DIR/a/port")"
ssh -p "$port_a" -i "$PROJECTS_DIR/a/ssh/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    app@127.0.0.1 true \
  || fail "the host could not ssh in with the project key"

# ...but not with B's key.
ssh -p "$port_a" -i "$PROJECTS_DIR/b/ssh/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    app@127.0.0.1 true 2>/dev/null \
  && fail "project B's key opened project A"
true
