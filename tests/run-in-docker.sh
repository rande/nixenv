#!/usr/bin/env bash
# =============================================================================
# tests/run-in-docker.sh — run the WHOLE suite inside docker-in-docker.
# Nothing on your machine is touched: nixenv, its projects, volumes, networks
# and the nix store all live inside a disposable privileged DinD container.
#
#   ./tests/run-in-docker.sh                 # unit + integration
#   ./tests/run-in-docker.sh unit            # just unit
#   NIXTEST_HEAVY=1 ./tests/run-in-docker.sh # include the slow flake-build test
#   ./tests/run-in-docker.sh --keep          # keep the DinD container afterwards
#
# Caching (avoid re-downloading):
#   * inner /var/lib/docker (images + the built nix store volume) persists in
#     the named volume nixenv-dind-cache across runs;
#   * on a FRESH cache, the host's already-built store volume is seeded into it
#     by local copy — no network (disable with SEED_STORE=0);
#   * the host's ~/.nixenv/context/flake.lock is reused so no github api calls.
# Start completely cold with:  docker volume rm nixenv-dind-cache
# =============================================================================
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
DIND_NAME="nixenv-dind"
DIND_IMAGE="${DIND_IMAGE:-docker:27-dind}"
SUITE="all"; KEEP=0
for a in "$@"; do case "$a" in
  unit|integration|all) SUITE="$a";;
  --keep) KEEP=1;;
  *) echo "usage: $0 [unit|integration|all] [--keep]"; exit 2;;
esac; done

command -v docker >/dev/null || { echo "docker required on the host"; exit 1; }

cleanup() { [ "$KEEP" = 1 ] || docker rm -f "$DIND_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker rm -f "$DIND_NAME" >/dev/null 2>&1 || true

echo "==> starting docker-in-docker ($DIND_IMAGE)"
# If the host has a built nixenv context, hand its flake.lock to the tests: a
# locked flake needs NO github api resolution (anonymous api.github.com calls
# are rate-limited and break the store build in fresh environments).
lockmount=()
if [ -f "$HOME/.nixenv/context/flake.lock" ]; then
  lockmount=(-v "$HOME/.nixenv/context/flake.lock:/host-flake.lock:ro")
  echo "==> reusing host flake.lock (skips github api resolution)"
fi
docker run -d --privileged --name "$DIND_NAME" \
  -e DOCKER_TLS_CERTDIR= \
  -v nixenv-dind-cache:/var/lib/docker \
  -v "$REPO_DIR":/repo:ro \
  ${lockmount[@]+"${lockmount[@]}"} \
  "$DIND_IMAGE" >/dev/null

echo "==> waiting for the inner docker daemon"
for i in $(seq 1 30); do
  docker exec "$DIND_NAME" docker info >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { echo "inner dockerd did not come up"; docker logs "$DIND_NAME" | tail -20; exit 1; }
  sleep 1
done

# ── Store seeding: reuse the HOST's built nix store instead of re-downloading ─
# If the host has the store volume and the inner one is empty, copy it across
# (pure local I/O — saves the multi-GB network build on a fresh cache volume).
STORE_VOL="${NIX_VOLUME:-nixenv__nixos_store}"
if [ "${SEED_STORE:-1}" = 1 ] && docker volume inspect "$STORE_VOL" >/dev/null 2>&1; then
  if ! docker exec "$DIND_NAME" test -d "/var/lib/docker/volumes/$STORE_VOL/_data/nix/var" 2>/dev/null; then
    echo "==> seeding inner store from the host volume '$STORE_VOL' (local copy, no downloads)"
    docker exec "$DIND_NAME" docker volume create "$STORE_VOL" >/dev/null
    docker run --rm \
      -v "$STORE_VOL":/src:ro \
      -v nixenv-dind-cache:/dst \
      debian:stable-slim sh -c \
      "cp -a /src/. /dst/volumes/$STORE_VOL/_data/ && echo '    seeded.'"
  fi
fi

echo "==> installing test prerequisites (bash, git, curl, ssh client)"
docker exec "$DIND_NAME" sh -c \
  'apk add --no-cache bash git curl openssh-client shadow >/dev/null'

# The suite must NOT run as uid 0: project containers run as the invoking uid,
# and sshd's PermitRootLogin=no would (correctly) reject uid-0 logins, breaking
# the ssh tests. Create a normal user and hand it the inner docker socket.
docker exec "$DIND_NAME" sh -c '
  id tester >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash tester
  chmod 666 /var/run/docker.sock
  rm -rf /work && cp -R /repo /work && chown -R tester /work
'

echo "==> running suite: $SUITE"
rc=0
docker exec -u tester -e HOME=/home/tester -e NIXTEST_HEAVY="${NIXTEST_HEAVY:-0}" \
  -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
  "$DIND_NAME" bash -c "cd /work && bash tests/run.sh $SUITE" || rc=$?
echo "==> suite finished (rc=$rc)"
exit "$rc"
