#!/usr/bin/env bash
# Template machinery: resolution (path/name/URL) + metadata parsing.
source "$(dirname "$0")/../lib.sh"
source_nixenv

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/demo.nix" <<'T'
# nixenv:description  Demo template
# nixenv:port         1234
# nixenv:allow        example.com .cdn.example.org
# nixenv:app-path     /srv/demo
{ }
T

# resolve_template — any EXISTING file wins, however it's written
assert_eq "$(resolve_template "$tmp/demo.nix")" "$tmp/demo.nix" "absolute path passthrough"
( cd "$tmp" && resolve_template "./demo.nix" >/dev/null ) || fail "./relative should resolve"
mkdir -p "$tmp/sub" && cp "$tmp/demo.nix" "$tmp/sub/x.nix"
( cd "$tmp" && assert_eq "$(resolve_template "sub/x.nix")" "sub/x.nix" "BARE relative path resolves" )
( cd "$tmp" && resolve_template "demo.nix" >/dev/null ) || fail "bare filename in cwd should resolve"
resolve_template "$tmp/nope.nix"  >/dev/null 2>&1 && fail "missing file must fail"  || true
resolve_template "sub/nope.nix"   >/dev/null 2>&1 && fail "missing relative path must fail" || true
resolve_template "nope.nix"       >/dev/null 2>&1 && fail ".nix that doesn't exist must fail" || true
resolve_template "bad name!"      >/dev/null 2>&1 && fail "invalid name must fail"  || true
resolve_template "ftp://x/y.nix"  >/dev/null 2>&1 && fail "bad scheme must fail"    || true

# a short name (no slash, no .nix, doesn't exist locally) must go to the base URL
# — proven by pointing the base at an unreachable host and expecting a fetch fail
( TEMPLATE_BASE="http://127.0.0.1:9/nonexistent" TEMPLATE_CACHE="$tmp/cache"
  resolve_template "wordpress" >/dev/null 2>&1 ) && fail "short name should try to fetch" || true

# template_meta
assert_eq "$(template_meta "$tmp/demo.nix" description)" "Demo template"
assert_eq "$(template_meta "$tmp/demo.nix" port)"        "1234"
assert_eq "$(template_meta "$tmp/demo.nix" allow)"       "example.com .cdn.example.org"
assert_eq "$(template_meta "$tmp/demo.nix" app-path)"    "/srv/demo"
assert_eq "$(template_meta "$tmp/demo.nix" nothere)"     ""  "absent key → empty"

# metadata must be readable with odd spacing / only the first match wins
printf '#nixenv:port 42\n#  nixenv:port  99\n' > "$tmp/sp.nix"
assert_eq "$(template_meta "$tmp/sp.nix" port)" "42" "tolerates spacing, takes the first"

# every shipped template is discoverable by its short name on disk
for t in wordpress cloudflare symfony headlesscms-directus-astro; do
  assert_file "$REPO_DIR/templates/$t.nix" "templates/$t.nix is shipped"
done
