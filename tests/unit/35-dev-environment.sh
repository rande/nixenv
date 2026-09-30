#!/usr/bin/env bash
# The nixenv-in-nixenv dev environment: engine sidecars (dev/engines.sh), the
# dev flake's clients, the hello example, and rootful podman support.
source "$(dirname "$0")/../lib.sh"
source_nixenv

# --- rootful podman must not get --userns=keep-id ------------------------------
ENGINE=docker; ENGINE_ROOTLESS=""
assert_eq "$(engine_userns)" "" "docker: no userns flag"
ENGINE=podman
podman() { [ "$1 $2" = "info --format" ] && echo "${FAKE_ROOTLESS:-true}"; }
FAKE_ROOTLESS=true;  ENGINE_ROOTLESS=""; assert_eq "$(engine_userns)" "--userns=keep-id" "rootless podman: keep-id"
FAKE_ROOTLESS=false; ENGINE_ROOTLESS=""; assert_eq "$(engine_userns)" "" "rootful podman: no keep-id (it rejects it)"
FAKE_ROOTLESS=false; ENGINE_ROOTLESS=true
assert_eq "$(engine_userns)" "--userns=keep-id" "the answer cached by require_engine wins"
podman() { return 1; }                                     # engine unreachable
ENGINE_ROOTLESS=""; assert_eq "$(engine_userns)" "--userns=keep-id" "unknown → old behaviour"
unset -f podman; ENGINE=""; ENGINE_ROOTLESS=""
rq="$(sed -n '/^require_engine()/,/^}/p' "$REPO_DIR/nixenv.sh" | code_only)"
assert_contains "$rq" 'ENGINE_ROOTLESS="$(podman_rootless_probe)"' "probed once, in the main shell"

# --- dev/engines.sh: the sidecar containers ---------------------------------------
# shellcheck disable=SC1091
source "$REPO_DIR/dev/engines.sh"
rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/devp"
printf '/srv/code' > "$PROJECTS_DIR/devp/app_mount"
ENGINE=docker
RUNLOG="$(mktemp)"
docker() { printf '%s\n' "$*" >> "$RUNLOG"; return 0; }
container_running() { return 1; }
: > "$RUNLOG"; start_dind devp >/dev/null 2>&1
d="$(cat "$RUNLOG")"
assert_contains "$d" "--privileged" "dind is privileged (a daemon needs it)"
assert_contains "$d" "--name ${CONTAINER_PREFIX}__devp-dind" "helper-style name (swept by 'stop')"
assert_contains "$d" "-v ${CONTAINER_PREFIX}_devp_home:/home/app " "home volume at the SAME path as the project"
assert_contains "$d" "-v ${CONTAINER_PREFIX}_devp_app:/srv/code " "app volume at the project's app_mount"
assert_contains "$d" "-v ${CONTAINER_PREFIX}_devp_engine:/var/run/nixenv " "socket volume"
assert_contains "$d" "--host=unix:///var/run/nixenv/docker.sock" "unix socket only"
assert_not_contains "$d" "tcp://" "no TCP listener"
assert_contains "$d" "DOCKER_TLS_CERTDIR= " "no TLS/tcp defaults from the dind entrypoint"
: > "$RUNLOG"; start_podman devp >/dev/null 2>&1
pm="$(cat "$RUNLOG")"
assert_contains "$pm" "--name ${CONTAINER_PREFIX}__devp-podman" "podman sidecar"
assert_contains "$pm" "podman system service --time=0 unix:///var/run/nixenv/podman.sock" "podman API on the socket"
assert_contains "$pm" "-v ${CONTAINER_PREFIX}_devp_app:/srv/code " "podman sees the same paths too"
rm -f "$RUNLOG"; unset -f docker

# The wait-then-open script is valid sh and opens the socket to the project.
sc="$(socket_script /var/run/nixenv/x.sock 'sleep 100')"
printf '%s\n' "$sc" | sh -n || fail "socket script does not parse"
assert_contains "$sc" "chmod 0666 '/var/run/nixenv/x.sock'" "socket opened (the volume is the boundary)"
assert_contains "$sc" 'kill -0' "notices a daemon that died instead of waiting forever"

# The project gets exactly one mount line, once.
write_extra_parameters devp
wire_project devp >/dev/null 2>&1 || fail "first wire should report a change"
wire_project devp >/dev/null 2>&1 && fail "second wire must be a no-op"
assert_eq "$(grep -c -- "-v ${CONTAINER_PREFIX}_devp_engine:/var/run/nixenv" "$PROJECTS_DIR/devp/extra-parameters")" "1" \
  "mount line added once"
assert_eq "$(project_extra_args devp)" "-v ${CONTAINER_PREFIX}_devp_engine:/var/run/nixenv" "and nixenv passes it to run"

# --- dev/flake.nix: clients point where the sidecars listen -------------------------
fl="$(cat "$REPO_DIR/dev/flake.nix")"
assert_contains "$fl" "sockDir = \"$ENGINE_SOCK_DIR\"" "flake and engines.sh agree on the socket dir"
assert_contains "$fl" 'DOCKER_HOST=unix://${sockDir}/docker.sock' "docker wrapper"
assert_contains "$fl" 'podman --remote' "podman talks to the remote service"
assert_contains "$fl" 'etc/nixenv-hooks.sh' "picks the nested engine at start"
paths="$(printf '%s\n' "$fl" | sed -n '/paths = \[/,/\];/p' | code_only)"
assert_not_contains "$paths" "docker-client" "real docker client referenced, not installed (bin/docker collision)"
assert_not_contains "$paths" "pkgs.podman" "real podman referenced, not installed (bin/podman collision)"
# `nixenv` on PATH runs the checkout under development.
assert_contains "$fl" 'pkgs.writeShellScriptBin "nixenv"' "nixenv command provided"
assert_contains "$(printf '%s\n' "$fl" | sed -n '/paths = \[/,/\];/p')" "              nixenv" "and installed"
# In a DOUBLE-quoted Nix string a literal ${ is \${; the ''${ escape only works
# inside indented strings — there it would make Nix interpolate and fail.
assert_contains "$fl" 'checkout = "\${NIXENV_APP_MOUNT:-/app}/nixenv.sh";' "checkout path escaped for a double-quoted string"
printf '%s\n' "$fl" | code_only | grep -q "= \"''\\\${" \
  && fail "a double-quoted Nix string uses the indented-string escape ''\${"
assert_contains "$fl" 'no executable ${checkout}' "clear error when the repo isn't the app volume"
# nixenv-docker / nixenv-podman: one engine each, separate state, this checkout.
assert_contains "$fl" '(nixenvFor "docker")' "nixenv-docker installed"
assert_contains "$fl" '(nixenvFor "podman")' "nixenv-podman installed"
assert_contains "$fl" 'export CONTAINER_ENGINE=${engine}' "pinned to its engine"
assert_contains "$fl" 'export HOME="$NIXENV_DEV_REAL_HOME/.nixenv-dev/${engine}"' \
  "separate nixenv state per engine (proxies would share squid.pid otherwise)"
assert_eq "$(printf '%s\n' "$fl" | grep -c 'exec "${checkout}" "$@"')" "2" \
  "nixenv and nixenv-<engine> both run the checkout under development, not an installed copy"
# Every nixenv state path must follow HOME, or the per-engine HOME isolates nothing.
for v in CONTEXT_DIR PROJECTS_DIR PROXY_DIR CLAUDE_DIR ENGINE_FILE GITHUB_TOKEN_FILE; do
  line="$(grep -m1 "^$v=" "$REPO_DIR/nixenv.sh")"
  assert_contains "$line" '$HOME/.nixenv' "$v lives under \$HOME"
done
[ -f "$REPO_DIR/flake.nix" ] && fail "no root flake.nix: the base flake is embedded in nixenv.sh (CLAUDE.md)"

# --- examples/hello --------------------------------------------------------------------
h="$REPO_DIR/examples/hello/flake.nix"
assert_eq "$(template_meta "$h" port)" "8080" "declares its port"
assert_contains "$(cat "$h")" "listen 0.0.0.0:\${httpPort}" "binds 0.0.0.0 (the proxy is another container)"
assert_contains "$(cat "$h")" 'writeTextDir "sv/hello/run"' "service declared as a file"
assert_contains "$(cat "$h")" "-e \${run}/error.log" "early error log is writable by app"
assert_not_contains "$(code_only < "$h")" '$HOME/' "nginx config paths are literal (nginx doesn't expand env)"
assert_contains "$(head -12 "$h")" "--template=examples/hello/flake.nix" "header shows how to init it"
true

# --- engines.sh copied out on its own (Homebrew flow: no clone on the host) -----
T2="$(mktemp -d)"; mkdir -p "$T2/bin"
cp "$REPO_DIR/nixenv.sh" "$T2/bin/nixenv"; chmod +x "$T2/bin/nixenv"
cp "$REPO_DIR/dev/engines.sh" "$T2/engines.sh"
out="$(PATH="$T2/bin:$PATH" bash "$T2/engines.sh" --help 2>&1)" || fail "lone engines.sh can't use the installed nixenv: $out"
assert_contains "$out" "engines.sh up nixenv" "usage shows the commands"
printf '#!/usr/bin/env bash\napp_volume() { :; }\n' > "$T2/bin/nixenv"      # an old nixenv
out="$(PATH="$T2/bin:$PATH" bash "$T2/engines.sh" --help 2>&1)" && fail "an outdated nixenv must be refused"
assert_contains "$out" "upgrade nixenv" "says how to fix an outdated nixenv"
rm -rf "$T2"
true
