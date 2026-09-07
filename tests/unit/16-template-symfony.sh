#!/usr/bin/env bash
# Template: symfony — shared invariants + Symfony specifics.
source "$(dirname "$0")/../lib.sh"
source_nixenv
source "$TESTS_DIR/lib-template.sh"

assert_template symfony
f="$REPO_DIR/templates/symfony.nix"; body="$(cat "$f")"

# the app is created at RUNTIME by composer — not vendored into the flake
assert_contains "$body" 'composer create-project' "skeleton created with composer"
assert_contains "$body" 'symfony/skeleton'        "uses the symfony skeleton"
assert_contains "$body" 'composer install'        "existing repos get their deps"
assert_contains "$body" '.symfony-installed'      "first-run marker"

# toolchain
for p in php83 composer symfony-cli nginx postgresql_16; do
  assert_contains "$body" "$p" "toolchain includes $p"
done

# nginx must use Symfony's front controller and the declared port
port="$(template_meta "$f" port)"
assert_contains "$body" "httpPort = \"${port}\"" "tunable matches # nixenv:port"
assert_contains "$body" 'listen ${httpPort}'      "nginx listens on that port"
assert_contains "$body" '/public'                 "docroot is public/"
assert_contains "$body" 'index.php$is_args$args'  "front-controller rewrite"
assert_contains "$body" "http_x_forwarded_proto" "trusts the proxy scheme"

# database wired to the persistent volume, and exposed to the app via .env.local
assert_contains "$body" '/databases/pgsql'        "DB on the persistent volume"
assert_contains "$body" 'DATABASE_URL'            "writes DATABASE_URL"
assert_contains "$body" '.env.local'              "uses .env.local (never committed)"

# packagist egress is required for composer
allow="$(template_meta "$f" allow)"
assert_contains "$allow" "repo.packagist.org"     "packagist allowed"
