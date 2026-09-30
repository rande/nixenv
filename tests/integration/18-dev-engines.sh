#!/usr/bin/env bash
# dev/engines.sh against a real engine: the project reaches the Docker AND Podman sidecars
# through its socket, and a container started THROUGH the sidecar sees the
# project's files at the same path — which is what lets a nested nixenv work.
source "$(dirname "$0")/../lib.sh" it
[ "$E" = docker ] || skip "dev/engines.sh targets a docker host"
sweep; trap 'bash "$REPO_DIR/dev/engines.sh" down p1 --purge >/dev/null 2>&1; sweep' EXIT
require_store

mkproj p1 --unrestricted
bash "$REPO_DIR/dev/engines.sh" up p1 >/dev/null || fail "engines up failed"
grep -q -- "-v nxt_p1_engine:/var/run/nixenv" "$NIXENV_PROJECTS_DIR/p1/extra-parameters" \
  || fail "extra-parameters not wired"
nx run p1 >/dev/null

dexec p1 sh -c 'test -S /var/run/nixenv/docker.sock' || fail "socket not visible in the project"
dexec p1 sh -c 'test -w /var/run/nixenv/docker.sock' || fail "socket not usable by the project user"

# Write from the project, read from a container the SIDECAR starts, same path.
dexec p1 sh -c 'echo path-identity-ok > "$HOME/.probe"'
out="$("$E" exec nxt__p1-dind docker run --rm -v /home/app/.probe:/probe:ro busybox cat /probe 2>&1)"
assert_eq "$out" "path-identity-ok" "nested bind mounts resolve to the project's files"

# Same through the Podman sidecar (rootful podman service).
dexec p1 sh -c 'test -S /var/run/nixenv/podman.sock' || fail "podman socket not visible in the project"
out="$("$E" exec nxt__p1-podman podman run --rm -v /home/app/.probe:/probe:ro docker.io/library/busybox cat /probe 2>&1)"
assert_eq "$out" "path-identity-ok" "podman: nested bind mounts resolve to the project's files"
true
