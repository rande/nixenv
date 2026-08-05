#!/usr/bin/env bash
# Custom app mount: workdir, env, login cd all honour --app-path.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

mkproj p2 --unrestricted --app-path=/srv/code
nx run p2 >/dev/null

assert_eq "$(dexec p2 sh -c 'echo "$NIXENV_APP_MOUNT"')" "/srv/code" "env"
assert_eq "$(dexec p2 sh -c 'pwd')" "/srv/code" "exec workdir"
assert_eq "$(dexec p2 "$PROFILE_PATH/bin/zsh" -lc 'pwd')" "/srv/code" "login shell cd"
dexec p2 sh -c 'touch /srv/code/x' || fail "app mount not writable"
involume nxt_p2_app 'test -f /v/x' || fail "file not at volume root"
