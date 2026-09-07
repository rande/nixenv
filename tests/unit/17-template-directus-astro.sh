#!/usr/bin/env bash
# Template: headlesscms-directus-astro — shared invariants + two-app specifics.
source "$(dirname "$0")/../lib.sh"
source_nixenv
source "$TESTS_DIR/lib-template.sh"

t=headlesscms-directus-astro
assert_template "$t"
f="$REPO_DIR/templates/$t.nix"; body="$(cat "$f")"

# toolchain
assert_contains "$body" 'nodejs_22'      "Node in the toolchain"
assert_contains "$body" 'postgresql_16'  "PostgreSQL in the toolchain"

# two apps, two folders, two services
assert_contains "$body" '/cms'   "CMS lives in cms/"
assert_contains "$body" '/web'   "frontend lives in web/"
for s in postgresql directus astro; do
  assert_contains "$body" "writeTextDir \"sv/$s/run\"" "declares the $s service"
done

# both servers must be reachable from the proxy container
port="$(template_meta "$f" port)"
assert_contains "$body" '--host 0.0.0.0'         "astro binds all interfaces"
assert_contains "$body" "webPort   = \"${port}\"" "tunable matches # nixenv:port"
assert_contains "$body" '--port ${webPort}'      "astro serves that port"
assert_contains "$body" 'HOST="0.0.0.0"'  "directus binds all interfaces"

# directus is installed + bootstrapped at runtime via npm/npx
assert_contains "$body" 'npm install directus' "directus installed with npm"
assert_contains "$body" 'directus bootstrap'   "schema bootstrapped once"
assert_contains "$body" 'DB_CLIENT'            "directus wired to postgres"
assert_contains "$body" '/databases/pgsql'     "DB on the persistent volume"
assert_contains "$body" '.directus-astro-installed' "first-run marker"

# secrets must be generated, never hardcoded
assert_contains "$body" '/dev/urandom'   "KEY/SECRET generated at setup"

# the frontend must talk to the CMS in-container, and expose the public URL
assert_contains "$body" '127.0.0.1'          "server-side calls stay in-container"
assert_contains "$body" 'PUBLIC_DIRECTUS_URL' "browser-side gets the public URL"

# npm egress is required
allow="$(template_meta "$f" allow)"
assert_contains "$allow" "registry.npmjs.org" "npm registry allowed"
