#!/usr/bin/env bash
# An archive's host-side files are someone else's input. Feed
# import_meta_files a hostile meta/ dir and check what lands in the project.
source "$(dirname "$0")/../lib.sh"
source_nixenv

body="$(cat "$REPO_DIR/nixenv.sh")"
imp="$(printf '%s' "$body" | sed -n '/^cmd_import()/,/^}/p' | code_only)"
assert_contains "$imp" 'import_meta_files' "import goes through the validating copier"
assert_not_contains "$imp" 'cp -a "$root/meta' "no verbatim cp -a of meta files"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
meta="$tmp/meta"; mkdir -p "$meta"
rm -rf "$PROJECTS_DIR"; pdir="$PROJECTS_DIR/evil"; mkdir -p "$pdir"

secret="$tmp/id_ed25519"; echo "PRIVATE KEY" > "$secret"
ln -s "$secret" "$meta/hosts.extra"                                  # symlink → a host secret
printf -- '--privileged\n--user 0\n-v /:/host\n' > "$meta/extra-parameters"
printf '8080\n3000:3000\n127.0.0.1:5173:5173\n0.0.0.0:2222:2222\n192.168.1.5:80:80\n' > "$meta/ports"
: > "$meta/unrestricted"
printf 'github.com\n*.npmjs.org\nhttp://evil/\nbad_host!\n' > "$meta/allowed_hosts"
printf '/etc' > "$meta/app_mount"
printf '../../../../etc' > "$meta/flake_dir"

out="$(import_meta_files "$meta" "$pdir" evil </dev/null 2>&1)"

# symlink ignored, nothing mounted from outside
[ -e "$pdir/hosts.extra" ] && fail "a symlinked hosts.extra was imported"
assert_contains "$out" "meta/hosts.extra is not a regular file" "says why"

# extra-parameters quarantined, never active
[ -e "$pdir/extra-parameters" ] && fail "extra-parameters became active"
assert_file "$pdir/extra-parameters.imported" "kept for review"
assert_contains "$out" "--privileged" "the parameters are shown"
assert_contains "$out" "NOT applied"  "and flagged as not applied"

# ports: loopback only; bare host:container pinned to loopback
p="$(cat "$pdir/ports")"
assert_contains "$p" "8080"                  "bare port kept"
assert_contains "$p" "127.0.0.1:3000:3000"   "host:container pinned to loopback"
assert_contains "$p" "127.0.0.1:5173:5173"   "loopback spec kept"
assert_not_contains "$p" "0.0.0.0"           "0.0.0.0 dropped"
assert_not_contains "$p" "192.168.1.5"       "LAN address dropped"

# unrestricted: no TTY → stays restricted
[ -e "$pdir/unrestricted" ] && fail "non-interactive import lifted egress restriction"
is_restricted evil || fail "project must stay restricted"

# allowed_hosts: re-validated
a="$(cat "$pdir/allowed_hosts")"
assert_contains "$a" "github.com"  "valid host kept"
assert_contains "$a" ".npmjs.org"  "wildcard normalised"
assert_not_contains "$a" "http"    "scheme entry dropped"
assert_not_contains "$a" "bad"     "invalid entry dropped"

# app_mount / flake_dir validated
[ -e "$pdir/app_mount" ] && fail "a reserved app path (/etc) was imported"
[ -e "$pdir/flake_dir" ] && fail "a traversing flake_dir was imported"

# a harmless archive still round-trips
rm -rf "$meta" "$pdir"; mkdir -p "$meta" "$pdir"
printf '/srv/code' > "$meta/app_mount"; printf 'infra/nixos' > "$meta/flake_dir"
printf '10.0.0.5\tdb\n' > "$meta/hosts.extra"
printf '# nixenv: comments only\n' > "$meta/extra-parameters"
import_meta_files "$meta" "$pdir" ok </dev/null >/dev/null 2>&1
assert_eq "$(cat "$pdir/app_mount")" "/srv/code"   "valid app path kept"
assert_eq "$(cat "$pdir/flake_dir")" "infra/nixos" "valid flake dir kept"
assert_file "$pdir/hosts.extra"                     "regular hosts.extra kept"
[ -L "$pdir/hosts.extra" ] && fail "hosts.extra must be a fresh regular file"
[ -e "$pdir/extra-parameters.imported" ] && fail "a comments-only scaffold is not quarantined"

# port spec classifier
for s in 8080 3000:3000 127.0.0.1:1:2; do safe_port_spec "$s" || fail "should accept $s"; done
for s in 0.0.0.0:1:2 10.0.0.1:1:2 '[::]:1:2' 1:2/udp ::1:2:3:4; do
  safe_port_spec "$s" && fail "should reject $s"
done

# cmd_run refuses symlinked meta files and bad app paths
run_fn="$(printf '%s' "$body" | sed -n '/^cmd_run()/,/^}/p' | code_only)"
assert_contains "$run_fn" 'is a symlink — refusing' "run refuses symlinked meta"
assert_contains "$run_fn" 'valid_app_mount "$appmnt"' "run re-validates the app path"
valid_app_mount '/x:ro' 2>/dev/null && fail "':' in an app path must be rejected"
true
