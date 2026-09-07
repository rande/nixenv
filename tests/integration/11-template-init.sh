#!/usr/bin/env bash
# init --template: local file is installed as flake.nix, metadata drives
# allowed_hosts / app-path, and an existing flake is never clobbered.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

tdir="$(mktemp -d)"; trap 'sweep; rm -rf "$tdir"' EXIT
cat > "$tdir/demo.nix" <<'T'
# nixenv:description  Demo
# nixenv:port         9999
# nixenv:allow        example.com .cdn.example.org
# nixenv:app-path     /srv/demo
{
  description = "demo — project @@PROJECT@@ at @@APP_MOUNT@@ on @@DOMAIN@@:@@PORT@@";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { self, nixpkgs, ... }: {
    packages.x86_64-linux.default = (import nixpkgs { system = "x86_64-linux"; }).hello;
    packages.aarch64-linux.default = (import nixpkgs { system = "aarch64-linux"; }).hello;
  };
}
T

# --yes skips the confirmation; no build (we only assert the install side)
nx init tpl --template="$tdir/demo.nix" --yes </dev/null >/dev/null 2>&1 || true

d="$NIXENV_PROJECTS_DIR/tpl"
assert_eq "$(cat "$d/app_mount")" "/srv/demo" "app-path from metadata"
ah="$(cat "$d/allowed_hosts")"
assert_contains "$ah" "example.com"        "allow from metadata"
assert_contains "$ah" ".cdn.example.org"   "allow keeps subdomain form"

# flake.nix landed in the app volume with placeholders substituted
flake="$(involume nxt_tpl_app 'cat /v/flake.nix')"
assert_contains "$flake" "project tpl"          "@@PROJECT@@ substituted"
assert_contains "$flake" "/srv/demo"            "@@APP_MOUNT@@ substituted"
assert_contains "$flake" "nixenv.localhost"     "@@DOMAIN@@ substituted"
assert_contains "$flake" ":9999"                "@@PORT@@ substituted"
assert_not_contains "$flake" "@@"               "no placeholders left"

# re-applying must NOT clobber an existing flake.nix
involume nxt_tpl_app 'echo MINE > /v/flake.nix'
nx init tpl --template="$tdir/demo.nix" --yes </dev/null >/dev/null 2>&1 || true
assert_eq "$(involume nxt_tpl_app 'cat /v/flake.nix')" "MINE" "existing flake preserved"

# a template and a git URL are mutually exclusive
if nx init tpl2 https://example.com/x.git --template="$tdir/demo.nix" --yes </dev/null >/dev/null 2>&1; then
  fail "template + git-url should be rejected"
fi
