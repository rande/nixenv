#!/usr/bin/env bash
# Shared helpers live in '<prefix>__…', outside the projects' '<prefix>-<name>'
# namespace; the old '<prefix>-proxy'/'<prefix>-egress' containers are cleaned
# up by command (never by name alone), and stale project containers are named.
source "$(dirname "$0")/../lib.sh"
source_nixenv

for v in PROXY_NAME EGRESS_NAME EGRESS_LINK; do
  eval "n=\$$v"
  case "$n" in "${CONTAINER_PREFIX}__"*) ;; *) fail "$v ($n) must be ${CONTAINER_PREFIX}__…";; esac
done
# No valid project name can produce a helper's name.
for p in proxy egress a b-c x_y; do
  for h in "$PROXY_NAME" "$EGRESS_NAME" "$EGRESS_LINK"; do
    [ "$(container_name "$p")" != "$h" ] || fail "project '$p' collides with $h"
  done
done
valid_project_name proxy 2>/dev/null && fail "'proxy' stays reserved (legacy cleanup relies on it)"
valid_project_name egress 2>/dev/null && fail "'egress' stays reserved"
# (captured first: `| grep -q` exits early and pipefail reports sed's SIGPIPE)
src="$(code_only < "$REPO_DIR/nixenv.sh")"
assert_contains "$src" 'visible_hostname nixenv-squid' "squid's visible_hostname must be a valid hostname (no '_')"

# --- legacy cleanup: by command, never by name alone --------------------------
ENGINE=docker
removed=""
container_exists() { case "$1" in "${CONTAINER_PREFIX}-proxy"|"${CONTAINER_PREFIX}-egress") return 0;; esac; return 1; }
docker() {
  case "$1" in
    inspect) case "$*" in
      *"${CONTAINER_PREFIX}-proxy"*)  echo '["sh","/etc/egress/start.sh"]';;
      *"${CONTAINER_PREFIX}-egress"*) echo '["sh","/usr/local/bin/nixenv-entrypoint"]';;  # a PROJECT named egress
    esac;;
    rm) removed="$removed ${*: -1}";;
  esac
  return 0
}
remove_legacy_helper proxy >/dev/null
remove_legacy_helper egress >/dev/null
assert_eq "$removed" " ${CONTAINER_PREFIX}-proxy" "only the real legacy helper is removed"
fn="$(declare -f cmd_proxy)"
clean_ln="$(printf '%s\n' "$fn" | grep -n 'remove_legacy_helper proxy' | head -1 | cut -d: -f1)"
start_ln="$(printf '%s\n' "$fn" | grep -n -- '--name "$PROXY_NAME"' | head -1 | cut -d: -f1)"
[ -n "$clean_ln" ] && [ -n "$start_ln" ] && [ "$clean_ln" -lt "$start_ln" ] \
  || fail "proxy up clears the old proxy BEFORE starting the new one (it holds the ports)"
assert_contains "$(declare -f egress_up)" "remove_legacy_helper egress"
assert_not_contains "$(declare -f egress_up)" "remove_legacy_helper proxy" "egress_up never takes ingress down"

# --- running containers created with the old names are named -----------------
docker() {
  [ "$1" = inspect ] || return 0
  case "$*" in
    *Config.Env*) printf 'NIXENV_PROXY_NAME=%s-proxy\nNIXENV_EGRESS_PROXY=http://%s-egress:3128\n' "$CONTAINER_PREFIX" "$CONTAINER_PREFIX";;
  esac
}
capture_ca_trusted() { return 1; }
out="$(container_needs_recreate p 1 2>&1)" && fail "a stale container is reported"
assert_contains "$out" "OLD egress proxy" "egress address"
assert_contains "$out" "OLD proxy name" "proxy name (public URLs from inside)"
out="$(container_needs_recreate p 0 2>&1)" && fail "unrestricted: the proxy name alone is stale"
assert_not_contains "$out" "egress" "unrestricted projects have no egress address"
docker() {
  [ "$1" = inspect ] || return 0
  case "$*" in *Config.Env*) printf 'NIXENV_PROXY_NAME=%s\nNIXENV_EGRESS_PROXY=http://%s:%s\n' "$PROXY_NAME" "$EGRESS_NAME" "$EGRESS_PORT";; esac
}
container_needs_recreate p 1 >/dev/null 2>&1 || fail "a current container is not stale"
assert_contains "$(declare -f cmd_proxy)" 'for _pd in "$PROJECTS_DIR"/*/' "proxy up checks every running project"
echo ok
