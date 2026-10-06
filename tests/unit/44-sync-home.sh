#!/usr/bin/env bash
# RUN-14: sync-home copies as the app user; root only repairs ownership.
source "$(dirname "$0")/../lib.sh"
source_nixenv

body="$(code_only < "$NIXENV_SH")"
fn="$(printf '%s\n' "$body" | sed -n '/^cmd_sync_home()/,/^}/p')"
[ -n "$fn" ] || fail "found cmd_sync_home"

# The helper that mounts the skeleton (the copy) runs as our uid, never -u 0.
copy="$(printf '%s\n' "$fn" | awk '/run --rm/{blk=""} {blk=blk $0 "\n"} /\/seed:ro/{print blk; exit}')"
assert_contains "$copy" '--user "$uid:$gid" $(engine_userns)' "the copy runs as the app user"
assert_contains "$copy" '${harden[@]+"${harden[@]}"}' "…with the runtime hardening"
assert_not_contains "$copy" '-u 0' "the copy never runs as root"
assert_contains "$fn" 'harden=($(container_hardening_args))' "copy helper is hardened"
assert_contains "$fn" 'cp -R --preserve=mode,timestamps' "ownership is not preserved from the source"
assert_not_contains "$fn" 'cp -a' "no cp -a (it carries the source owner)"

# The root step only repairs ownership, in the project container's userns.
root="$(printf '%s\n' "$fn" | grep -n -- '-u 0' )"
assert_eq "$(printf '%s\n' "$root" | grep -c .)" 1 "exactly one root helper (the repair)"
assert_contains "$root" '$(engine_userns)' "repair uses the same userns as the container"
assert_contains "$fn" 'chown -h "$NIXUID:$NIXGID"' "repair re-owns what isn't ours"
