# =============================================================================
# tests/lib.sh — shared harness for the nixenv test suite (sourced, not run)
# =============================================================================
# One bash file per test. Each test:
#   source "$(dirname "$0")/../lib.sh"     (unit)  — pure logic, no engine
#   source "$(dirname "$0")/../lib.sh" it  (integration) — docker required
# Exit codes: 0 = pass, 77 = skip, anything else = fail.
#
# The suite is designed for a DEDICATED environment (KVM/CI): integration tests
# sweep every container/volume/network with the test prefix, and use isolated
# state dirs — but they intentionally REUSE the shared nix store volume
# (nixenv__nixos_store) because building it takes long (test 00 builds it once).
# =============================================================================

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
NIXENV_SH="$REPO_DIR/nixenv.sh"
[ -f "$NIXENV_SH" ] || { echo "FAIL: nixenv.sh not found at $NIXENV_SH" >&2; exit 1; }

# ── Isolated state (never touches ~/.nixenv of a real user) ──────────────────
NIXTEST_HOME="${NIXTEST_HOME:-${TMPDIR:-/tmp}/nixenv-tests}"
export NIXENV_PROJECTS_DIR="$NIXTEST_HOME/projects"
export PROXY_DIR="$NIXTEST_HOME/proxy"
export CLAUDE_DIR="$NIXTEST_HOME/claude"
export CLAUDE_JSON="$NIXTEST_HOME/claude.json"
export GITHUB_TOKEN_FILE="$NIXTEST_HOME/github_token"
export GITHUB_TOKEN_SKIP="$NIXTEST_HOME/github_token.skip"
unset GITHUB_TOKEN
export CONTEXT_DIR="$NIXTEST_HOME/context"
# The remembered engine choice too: with BOTH docker and podman on PATH and no
# choice yet (the dev project — dev/flake.nix wraps both clients), nixenv asks
# which to use. Unit tests send output to /dev/null, so that prompt was
# invisible and the suite just hung; and answering it wrote the user's real
# ~/.nixenv/engine.
export ENGINE_FILE="$NIXTEST_HOME/engine"
export CONTAINER_PREFIX="nxt"                 # containers nxt-*, volumes nxt_*, nets nxt_*
# The store volume follows the prefix too; the suite deliberately reuses the
# already-built one instead of building nxt__nixos_store.
export NIX_VOLUME="${NIX_VOLUME:-nixenv__nixos_store}"
export PROXY_HTTP_PORT=18080 PROXY_HTTPS_PORT=18443
export EGRESS_NET="nxt_net-egress"            # swept with the other nxt_* networks
export PROXY_MKCERT_INSTALL=0                 # never touch trust stores in tests
export GIT_USER_NAME="Nix Test" GIT_USER_EMAIL="test@nixenv.local"
mkdir -p "$NIXTEST_HOME"

# ── Result helpers ───────────────────────────────────────────────────────────
fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  ... $*"; }

assert_eq()        { [ "$1" = "$2" ]        || fail "${3:-assert_eq}: expected [$2], got [$1]"; }
# Strip shell/Nix `#` comments from stdin. Use this before grepping source for a
# pattern that the code's own comments are likely to mention — this repo
# documents its traps in comments right next to the fix, so a naive grep matches
# the warning instead of the code. It has caught us out three times: the bare
# `''` rule, `[ -t 2 ] &&`, and an `ensure_volumes` ordering check.
# (Not a real parser: a `#` inside a string is stripped too. Fine for grepping,
# wrong for anything that must preserve the code exactly.)
code_only() { sed 's/[[:space:]]*#.*//'; }

assert_contains()  { case "$1" in *"$2"*) ;; *) fail "${3:-assert_contains}: [$2] not found in: $1";; esac; }
assert_not_contains(){ case "$1" in *"$2"*) fail "${3:-assert_not_contains}: [$2] unexpectedly present";; esac; }
assert_file()      { [ -f "$1" ] || fail "${2:-assert_file}: missing file $1"; }
assert_no_file()   { [ ! -e "$1" ] || fail "${2:-assert_no_file}: $1 should not exist"; }

# Run nixenv as a COMMAND (fresh process, isolated env above applies).
# A terminal stdin is detached: a test must never block on an interactive prompt
# (its output usually goes to /dev/null, so you wouldn't even see it). Piped
# stdin is kept — `printf 'y\n' | nx delete …` is how tests answer prompts.
nx() {
  if [ -t 0 ]; then bash "$NIXENV_SH" "$@" </dev/null
  else bash "$NIXENV_SH" "$@"
  fi
}

# Unit tests (after source_nixenv): does an export carry <relpath> of the
# project dir? exports_path <relpath> [with_home=0|1]
exports_path() {
  local d rc=0; d="$(mktemp -d)"
  mkdir -p "$d/$(dirname "$1")"; echo x > "$d/$1"
  export_project_files "$d" "${2:-0}" | grep -qxF "$1" || rc=1
  rm -rf "$d"; return "$rc"
}

# Source nixenv.sh for unit tests (functions defined, nothing executed).
source_nixenv() {
  # shellcheck disable=SC1090
  source "$NIXENV_SH"
}

# ── Integration mode ─────────────────────────────────────────────────────────
if [ "${1:-}" = "it" ]; then
  export CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
  E="$CONTAINER_ENGINE"
  command -v "$E" >/dev/null 2>&1 || skip "container engine '$E' not installed"
  "$E" info >/dev/null 2>&1       || skip "container engine '$E' daemon not reachable"

  STORE_VOL="${NIX_VOLUME:-nixenv__nixos_store}"
  PROFILE_PATH="/nix/var/nix/profiles/shared"

  # Remove every test-prefixed container/volume/network + the state dir.
  sweep() {
    local ids
    # nxt-* projects/proxy AND nxt__* helpers (deploy containers, dev sidecars).
    ids="$("$E" ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^nxt(-|__)' || true)"
    [ -n "$ids" ] && "$E" rm -f $ids >/dev/null 2>&1 || true
    ids="$("$E" volume ls -q 2>/dev/null | grep '^nxt_' || true)"
    [ -n "$ids" ] && "$E" volume rm -f $ids >/dev/null 2>&1 || true
    ids="$("$E" network ls --format '{{.Name}}' 2>/dev/null | grep '^nxt_' || true)"
    for n in $ids; do "$E" network rm "$n" >/dev/null 2>&1 || true; done
    rm -rf "$NIXTEST_HOME"; mkdir -p "$NIXTEST_HOME"
  }

  require_store() {
    "$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
      test -x "$PROFILE_PATH/bin/zsh" >/dev/null 2>&1 \
      || skip "shared store not built — run test 00-store-build (or ./nixenv.sh build)"
  }
  require_store_bin() {
    "$E" run --rm -v "$STORE_VOL":/nix debian:stable-slim \
      test -x "$PROFILE_PATH/bin/$1" >/dev/null 2>&1 \
      || skip "'$1' missing from the store — rebuild with ./nixenv.sh build"
  }

  # docker exec in a test project container: dexec <project> <cmd...>
  dexec() { local p="$1"; shift; "$E" exec "nxt-$p" "$@"; }
  # run a throwaway container with a named volume at /v: involume <vol> <sh -c script>
  involume() { "$E" run --rm -v "$1":/v debian:stable-slim sh -c "$2"; }

  # Create a project non-interactively (no clone): mkproj <name> [init-args...]
  mkproj() { local n="$1"; shift; nx init "$n" "$@" </dev/null >/dev/null; }

  wait_tcp() {  # wait_tcp <port> [seconds]
    local port="$1" t="${2:-15}" i=0
    while [ "$i" -lt "$t" ]; do
      if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
      sleep 1; i=$((i+1))
    done
    return 1
  }

  ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o LogLevel=ERROR -o ConnectTimeout=8)
fi
