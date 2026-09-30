#!/usr/bin/env bash
# =============================================================================
# dev/engines.sh — container engines for a nixenv project that develops nixenv
# =============================================================================
# Run on the HOST (where nixenv itself runs). With a clone it uses the clone's
# nixenv.sh; copied out on its own (Homebrew flow, see DEVELOPING.md) it uses
# the installed `nixenv`:
#
#   ./dev/engines.sh up nixenv            # Docker + Podman sidecars for project 'nixenv'
#   ./dev/engines.sh up nixenv --docker   # only Docker (or --podman)
#   ./dev/engines.sh status nixenv
#   ./dev/engines.sh down nixenv [--purge]   # --purge also deletes their images/volumes
#
# WHY SIDECARS. A nixenv project container runs as your uid with every
# capability dropped and no-new-privileges. No engine can run inside it:
# dockerd needs root, and rootless podman needs setuid newuidmap, which the Nix
# store can't carry. So each engine runs in its own PRIVILEGED container next to
# the project, and the project talks to it over a Unix socket.
#
# HOW THE PIECES MEET
#   * sockets  — both daemons listen on sockets in the volume
#                <prefix>_<project>_engine, which the project mounts at
#                /var/run/nixenv (one line added to its extra-parameters). No
#                TCP port, so nothing else on the machine can reach them.
#   * paths    — the sidecars mount the project's HOME and APP volumes at the
#                SAME paths the project sees (/home/app, and /app or its
#                app_mount). The nested nixenv bind-mounts files from its
#                ~/.nixenv and the repo; the daemon resolves those paths on its
#                own filesystem, so they must be identical there.
#   * clients  — dev/flake.nix wraps `docker` and `podman` to use those sockets.
#
# SECURITY. Privileged sidecars are root on the engine's VM/host, and whoever
# can use their socket can start privileged containers. Only this project
# mounts the socket volume — but code running in it (tests, git hooks, your
# dependencies) effectively has root on the Docker VM, and full network access
# through the engines, whatever its egress allowlist says. Use it for your own
# nixenv checkout, not for untrusted code.
#
# Targets Docker (Docker Desktop, or rootful Docker on Linux). Privileged
# containers under ROOTLESS podman on the host are limited; expect trouble there.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse nixenv's own naming and helpers so volume/container names never drift.
# (nixenv.sh only runs `main` when executed, not when sourced.)
# Which nixenv: $NIXENV_SH if set; else the repo this script sits in; else the
# INSTALLED `nixenv` — the Homebrew flow has no clone on the host, only this
# script copied out of the dev project.
if [ -n "${NIXENV_SH:-}" ]; then
  _nixenv_lib="$NIXENV_SH"
elif [ -f "$HERE/../nixenv.sh" ]; then
  _nixenv_lib="$HERE/../nixenv.sh"
elif command -v nixenv >/dev/null 2>&1; then
  _nixenv_lib="$(command -v nixenv)"
else
  echo "engines.sh: can't find nixenv — install it (brew install rande/nixenv/nixenv) or set NIXENV_SH" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$_nixenv_lib"
# An older installed nixenv may lack helpers this script relies on.
for _fn in app_volume home_volume project_app_mount ensure_volumes container_running \
           container_name write_extra_parameters project_extra_args valid_project_name img; do
  if ! command -v "$_fn" >/dev/null 2>&1; then
    echo "engines.sh: $_nixenv_lib has no '$_fn' — upgrade nixenv (brew upgrade nixenv)" >&2
    exit 1
  fi
done

DIND_IMAGE="${DIND_IMAGE:-docker:dind}"
PODMAN_IMAGE="${PODMAN_IMAGE:-quay.io/podman/stable}"
ENGINE_SOCK_DIR="/var/run/nixenv"          # inside the project AND the sidecars

engine_volume()      { printf '%s_%s_engine' "$CONTAINER_PREFIX" "$1"; }
dind_data_volume()   { printf '%s_%s_dind' "$CONTAINER_PREFIX" "$1"; }
podman_data_volume() { printf '%s_%s_podmanstore' "$CONTAINER_PREFIX" "$1"; }
# `__` marks helper containers; `nixenv stop` (no args) sweeps them too.
sidecar_name()       { printf '%s__%s-%s' "$CONTAINER_PREFIX" "$1" "$2"; }

# The one line the project needs in extra-parameters.
engine_mount_line()  { printf -- '-v %s:%s' "$(engine_volume "$1")" "$ENGINE_SOCK_DIR"; }

usage() { sed -n '9,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Wait for a socket inside a sidecar, then open it to the project. 0666 is
# deliberate: the socket lives in a volume only this project and the sidecars
# mount, so the volume is the access boundary. Matching group ownership instead
# breaks whenever the engine remaps ids (rootless hosts, keep-id).
socket_script() {  # $1 = socket path, $2 = daemon command (backgrounded)
  cat <<EOF
set -e
rm -f '$1'
$2 &
daemon=\$!
i=0
until [ -S '$1' ]; do
  i=\$((i + 1)); [ "\$i" -lt 300 ] || { echo "daemon never created $1" >&2; exit 1; }
  kill -0 "\$daemon" 2>/dev/null || { echo "daemon exited before creating $1" >&2; exit 1; }
  sleep 0.2
done
chmod 0666 '$1'
echo "nixenv-dev: $1 ready"
wait "\$daemon"
EOF
}

# The project's volumes, mounted where the project sees them.
project_mounts() {  # $1 = project → prints -v args, one per line
  printf '%s\n' -v "$(home_volume "$1"):/home/$APP_USER"
  printf '%s\n' -v "$(app_volume "$1"):$(project_app_mount "$1")"
  printf '%s\n' -v "$(engine_volume "$1"):$ENGINE_SOCK_DIR"
}

start_dind() {
  local p="$1" name mounts; name="$(sidecar_name "$p" dind)"
  if container_running "$name"; then ok "docker sidecar already running ($name)"; return 0; fi
  "$ENGINE" rm -f "$name" >/dev/null 2>&1 || true
  mounts=(); while IFS= read -r l; do mounts+=("$l"); done < <(project_mounts "$p")
  log "starting the docker sidecar ($name, $DIND_IMAGE)"
  "$ENGINE" run -d --name "$name" --privileged \
    -e DOCKER_TLS_CERTDIR= \
    -v "$(dind_data_volume "$p")":/var/lib/docker \
    "${mounts[@]}" \
    --entrypoint sh "$(img "$DIND_IMAGE")" \
    -c "$(socket_script "$ENGINE_SOCK_DIR/docker.sock" \
          "dockerd-entrypoint.sh dockerd --host=unix://$ENGINE_SOCK_DIR/docker.sock")" \
    >/dev/null || die "could not start $name"
}

start_podman() {
  local p="$1" name mounts; name="$(sidecar_name "$p" podman)"
  if container_running "$name"; then ok "podman sidecar already running ($name)"; return 0; fi
  "$ENGINE" rm -f "$name" >/dev/null 2>&1 || true
  mounts=(); while IFS= read -r l; do mounts+=("$l"); done < <(project_mounts "$p")
  log "starting the podman sidecar ($name, $PODMAN_IMAGE)"
  "$ENGINE" run -d --name "$name" --privileged \
    -v "$(podman_data_volume "$p")":/var/lib/containers \
    "${mounts[@]}" \
    --entrypoint sh "$(img "$PODMAN_IMAGE")" \
    -c "$(socket_script "$ENGINE_SOCK_DIR/podman.sock" \
          "podman system service --time=0 unix://$ENGINE_SOCK_DIR/podman.sock")" \
    >/dev/null || die "could not start $name"
}

wait_socket() {  # $1 = project, $2 = dind|podman, $3 = socket file name
  local name i; name="$(sidecar_name "$1" "$2")"
  for i in $(seq 1 60); do
    "$ENGINE" exec "$name" test -S "$ENGINE_SOCK_DIR/$3" 2>/dev/null && { ok "$3 is up"; return 0; }
    container_running "$name" || break
    sleep 1
  done
  "$ENGINE" logs --tail 20 "$name" >&2 2>&1 || true
  die "$2 sidecar did not come up — logs above ($ENGINE logs $name)"
}

# Add the socket mount to the project's extra-parameters, once.
wire_project() {
  local p="$1" f line; f="$(project_dir "$p")/extra-parameters"; line="$(engine_mount_line "$p")"
  write_extra_parameters "$p"
  if grep -qF -- "$line" "$f"; then
    ok "extra-parameters already mounts the engine sockets"
    return 1
  fi
  printf '\n# dev/engines.sh: Docker/Podman sidecar sockets at %s\n%s\n' "$ENGINE_SOCK_DIR" "$line" >> "$f"
  ok "added to $f:  $line"
  return 0
}

cmd_up() {
  local p="$1" want_docker="$2" want_podman="$3" changed=0
  [ -d "$(project_dir "$p")" ] || die "no project '$p' — create it first:  ./nixenv.sh init $p <git-url>"
  require_engine
  ensure_volumes "$p"                           # the sidecars mount them
  "$ENGINE" volume create "$(engine_volume "$p")" >/dev/null 2>&1 || true
  # (if/fi, not `[ ] && cmd`: a false test would trip set -e in this repo's style)
  if [ "$want_docker" = 1 ]; then start_dind "$p"; fi
  if [ "$want_podman" = 1 ]; then start_podman "$p"; fi
  if [ "$want_docker" = 1 ]; then wait_socket "$p" dind docker.sock; fi
  if [ "$want_podman" = 1 ]; then wait_socket "$p" podman podman.sock; fi
  if wire_project "$p"; then changed=1; fi
  echo
  ok "engines ready for '$p'"
  if container_running "$(container_name "$p")" && [ "$changed" = 1 ]; then
    warn "'$p' is running without the socket mount — recreate it:"
    echo "    ./nixenv.sh stop $p && ./nixenv.sh run $p"
  fi
  echo "   inside the project:  docker info   /   podman info"
  echo "   (with dev/flake.nix built:  ./nixenv.sh build $p --dir=dev)"
}

cmd_down() {
  local p="$1" purge="$2" s
  require_engine
  for s in dind podman; do
    if "$ENGINE" rm -f "$(sidecar_name "$p" "$s")" >/dev/null 2>&1; then ok "removed $(sidecar_name "$p" "$s")"; fi
  done
  if [ "$purge" = 1 ]; then
    "$ENGINE" volume rm "$(dind_data_volume "$p")" "$(podman_data_volume "$p")" "$(engine_volume "$p")" \
      >/dev/null 2>&1 || true
    ok "deleted the sidecars' volumes (images, nested nix store, sockets)"
  else
    echo "   their images and nested nix store are kept — '--purge' deletes them"
  fi
}

cmd_status() {
  local p="$1" s name
  require_engine
  for s in dind podman; do
    name="$(sidecar_name "$p" "$s")"
    if container_running "$name"; then ok "$s sidecar running ($name)"
    else warn "$s sidecar not running"; fi
  done
  if grep -qF -- "$(engine_mount_line "$p")" "$(project_dir "$p")/extra-parameters" 2>/dev/null; then
    ok "project '$p' mounts the sockets at $ENGINE_SOCK_DIR"
  else
    warn "project '$p' doesn't mount the sockets yet — run: $0 up $p"
  fi
}

engines_main() {
  local sub="${1:-}" p="${2:-}" docker=1 podman=1 purge=0
  [ -n "$sub" ] || usage 1
  case "$sub" in -h|--help|help) usage 0;; esac
  [ -n "$p" ] || usage 1
  valid_project_name "$p" || exit 1
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --docker) podman=0;;
      --podman) docker=0;;
      --purge)  purge=1;;
      *) die "unknown option: $1";;
    esac
    shift
  done
  case "$sub" in
    up)     cmd_up "$p" "$docker" "$podman";;
    down)   cmd_down "$p" "$purge";;
    status) cmd_status "$p";;
    *) usage 1;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then engines_main "$@"; fi
