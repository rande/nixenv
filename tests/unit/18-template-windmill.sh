#!/usr/bin/env bash
# Template: windmill — shared invariants + Windmill specifics.
source "$(dirname "$0")/../lib.sh"
source_nixenv
source "$TESTS_DIR/lib-template.sh"

assert_template windmill
f="$REPO_DIR/templates/windmill.nix"; body="$(cat "$f")"

# toolchain: one binary with the frontend embedded, plus a database
assert_contains "$body" 'pkgs.windmill'    "uses the nixpkgs windmill package"
assert_contains "$body" 'postgresql_16'    "ships PostgreSQL"

# the "latest upstream release" escape hatch must stay opt-in and fully pinned
assert_contains "$body" 'useUpstreamBinary = false' "upstream binary is opt-in"
printf '%s' "$body" | grep -qE 'upstreamSha256 *= *"[0-9a-f]{64}"' \
  || fail "upstream binary must be pinned by a full sha256"
assert_contains "$body" 'fetchurl'          "upstream binary fetched by URL+hash"
assert_contains "$body" 'autoPatchelfHook'  "upstream ELF is patched for the store"
# ...and must refuse the arch upstream does not publish, rather than fail obscurely
assert_contains "$body" 'x86_64-linux only' "guards the unsupported arch"

# the compose stack becomes runit services — server + BOTH worker groups
for s in postgresql windmill-server windmill-worker windmill-worker-native; do
  assert_contains "$body" "writeTextDir \"sv/$s/run\"" "declares the $s service"
done
assert_contains "$body" 'MODE=server'          "server mode"
assert_contains "$body" 'WORKER_GROUP=default' "default worker group"
assert_contains "$body" 'WORKER_GROUP=native'  "native worker group"
assert_contains "$body" 'NATIVE_MODE=true'     "native worker is in native mode"

# every windmill process must wait for the database rather than crash-loop
n="$(printf '%s' "$body" | grep -c 'pg_isready -h 127.0.0.1 -p 5432 -q')"
[ "$n" -ge 3 ] || fail "each windmill service must gate on pg_isready (found $n)"

# the server must be reachable from the proxy container on the declared port
port="$(template_meta "$f" port)"
assert_contains "$body" "httpPort = \"${port}\"" "tunable matches # nixenv:port"
assert_contains "$body" 'export PORT=${httpPort}' "server listens on that port"

# WM_BASE_URL drives webhook/OAuth URLs — must be the public URL, not localhost
assert_contains "$body" 'WM_BASE_URL'  "sets the base url"
assert_contains "$body" 'baseUrl  = "https://@@PROJECT@@-${httpPort}.@@DOMAIN@@"' \
  "base url is the public proxy URL"
printf '%s' "$body" | grep -q 'WM_BASE_URL="https\?://localhost' \
  && fail "WM_BASE_URL must not be localhost (webhooks would be unreachable)"

# database wired to the persistent volume
assert_contains "$body" '/databases/pgsql' "DB on the persistent volume"
assert_contains "$body" 'postgres://${dbUser}@127.0.0.1:5432/${dbName}' "DATABASE_URL form"

# migrations need these roles to pre-exist (upstream init-db-as-superuser.sql)
assert_contains "$body" 'CREATE ROLE windmill_user'                 "creates windmill_user"
assert_contains "$body" 'CREATE ROLE windmill_admin WITH BYPASSRLS' "creates windmill_admin"
assert_contains "$body" 'GRANT windmill_admin TO ${dbUser}'         "grants admin to the app user"
# a DO $$…$$ block would need $$ in shell (= PID) and a heredoc in a Nix '' string
# (comments stripped — they may legitimately mention the anti-pattern)
printf '%s' "$body" | sed 's/[[:space:]]*#.*//' | grep -q 'DO \$\$' \
  && fail "role setup must not use a DO \$\$ block (\$\$ is the shell's PID)"

# nsjail cannot work in an unprivileged container — must be explicitly off
assert_contains "$body" 'DISABLE_NSJAIL=true' "nsjail disabled (no privileges here)"

# first-run marker, and no attempt to vendor state into the flake
assert_contains "$body" '.windmill-installed' "first-run marker"

# git sync: the CLI is on PATH and the app volume is scaffolded for MULTIPLE
# workspaces (wmill sync is scoped to cwd + selected workspace, so one dir each)
assert_contains "$body" 'writeShellScriptBin "wmill"' "ships the wmill CLI"
assert_contains "$body" 'wmillCli'                    "wmill is in buildEnv paths"
assert_contains "$body" 'jsr:@windmill-labs/wmill'    "CLI comes from JSR"
assert_contains "$body" 'mkdir -p "$APP/workspaces"'  "scaffolds a per-workspace root"
assert_contains "$body" 'workspace switch'            "documents switching workspaces"
assert_contains "$body" '.gitignore'                  "writes a .gitignore"
# the hook must NOT sync on its own: sync deletes whatever the source lacks
printf '%s' "$body" | sed 's/[[:space:]]*#.*//' | grep -qE '^\s*(wmill )?sync (pull|push)' \
  && fail "the startup hook must never run wmill sync (it is destructive)"

# job runtimes fetch dependencies at run time; jsr/deno are needed by the CLI
allow="$(template_meta "$f" allow)"
for h in pypi.org .npmjs.org .windmill.dev jsr.io deno.land; do
  assert_contains "$allow" "$h" "egress allows $h"
done
