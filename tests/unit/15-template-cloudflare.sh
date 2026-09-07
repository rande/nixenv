#!/usr/bin/env bash
# Template: cloudflare — shared invariants + wrangler specifics.
source "$(dirname "$0")/../lib.sh"
source_nixenv
source "$TESTS_DIR/lib-template.sh"

assert_template cloudflare
f="$REPO_DIR/templates/cloudflare.nix"; body="$(cat "$f")"

# toolchain
assert_contains "$body" 'nodejs_22'   "Node in the toolchain"
assert_contains "$body" 'wrangler'    "wrangler in the toolchain"

# the dev server MUST be reachable from the proxy container
port="$(template_meta "$f" port)"
assert_contains "$body" '--ip 0.0.0.0'          "binds all interfaces"
assert_contains "$body" "devPort = \"${port}\"" "tunable matches # nixenv:port"
assert_contains "$body" '--port ${devPort}'      "serves that port"

# a project's own pinned wrangler should win over the nixpkgs one
assert_contains "$body" 'node_modules/.bin/wrangler' "prefers the project's wrangler"

# scaffolding is one-time and must not clobber an existing project
assert_contains "$body" '.cloudflare-scaffolded'  "first-run marker"
assert_contains "$body" 'existing project detected' "skips scaffold when files exist"
assert_contains "$body" 'npm install'             "installs deps for existing repos"

# scaffold produces a usable worker
assert_contains "$body" 'wrangler.toml'   "writes a wrangler config"
assert_contains "$body" 'compatibility_date' "config has a compatibility date"
assert_contains "$body" 'src/index.ts'    "writes a worker entrypoint"

# egress for npm + cloudflare
allow="$(template_meta "$f" allow)"
assert_contains "$allow" "registry.npmjs.org" "npm registry allowed"
assert_contains "$allow" "cloudflare.com"     "cloudflare hosts allowed"
