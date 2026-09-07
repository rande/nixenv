#!/usr/bin/env bash
# Template: wordpress — shared invariants + WordPress specifics.
source "$(dirname "$0")/../lib.sh"
source_nixenv
source "$TESTS_DIR/lib-template.sh"

assert_template wordpress
f="$REPO_DIR/templates/wordpress.nix"; body="$(cat "$f")"

# WordPress is installed at RUNTIME by wp-cli — not vendored into the flake.
assert_contains "$body" 'wp core download'      "core fetched with wp-cli"
assert_contains "$body" 'wp core install'       "site installed with wp-cli"
assert_contains "$body" 'wp-cli'                "wp-cli is in the toolchain"
assert_not_contains "$body" 'pkgs.wordpress'    "core NOT vendored from nixpkgs"

# plugins are declared in one place and installed once
assert_contains "$body" 'wpPlugins'             "plugin list is a tunable"
assert_contains "$body" 'query-monitor'         "ships the standard dev plugin"
assert_contains "$body" 'plugin install'        "plugins installed with wp-cli"

# stack + persistence
for p in php83 nginx mariadb; do
  assert_contains "$body" "$p" "toolchain includes $p"
done
assert_contains "$body" '/databases/mysql'      "DB lives on the persistent volume"
assert_contains "$body" '.wordpress-installed'  "first-run marker"

# behind the reverse proxy: WP must see the forwarded scheme as https
assert_contains "$body" 'HTTP_X_FORWARDED_PROTO' "trusts the proxy's scheme"

# the declared port must be the one the stack is configured with
port="$(template_meta "$f" port)"
assert_contains "$body" "httpPort  = \"${port}\"" "tunable matches # nixenv:port"
assert_contains "$body" 'listen ${httpPort}'      "nginx listens on that port"

# egress needed by wp-cli must be declared
allow="$(template_meta "$f" allow)"
assert_contains "$allow" "downloads.wordpress.org" "core download host allowed"
assert_contains "$allow" "api.wordpress.org"       "plugin API host allowed"
