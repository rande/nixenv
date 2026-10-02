#!/usr/bin/env bash
# export/import: the pure logic — which host-side files travel, manifest
# round-trip, and the guards that make an import safe on a different machine.
source "$(dirname "$0")/../lib.sh"
source_nixenv

body="$(cat "$REPO_DIR/nixenv.sh")"
exp="$(printf '%s' "$body" | sed -n '/^cmd_export()/,/^}/p')"
imp="$(printf '%s' "$body" | sed -n '/^cmd_import()/,/^}/p')"

# --- everything under <project>/ travels, except what is regenerated ----------
for f in ports app_mount hosts.extra allowed_hosts unrestricted extra-parameters \
         flake_dir accept-from ssh_hosts deploy_hosts some-new-file \
         home/.zshrc home/.gitconfig home/.gitconfig.identity home/.config/nvim/init.lua \
         ssh/authorized_keys.extra; do
  exports_path "$f" || fail "an export should carry $f"
done
# Machine-specific state must NEVER travel: restoring it onto another uid gives a
# container that cannot write its own files, or a port already in use here.
for f in passwd group shadow port etc-hosts flake/flake.nix flake/flake.lock \
         ssh/config ssh/known_hosts ssh/authorized_keys ssh/id_ed25519 ssh/host_ed25519_key; do
  exports_path "$f" 1 && fail "an export must not carry machine-specific '$f'"
done
# Secrets in the seed travel only with --with-home, like the home volume.
for f in home/.git-credentials home/.gitconfig.credentials home/.ssh/id_ed25519; do
  exports_path "$f" 0 && fail "$f must not travel without --with-home"
  exports_path "$f" 1 || fail "$f should travel with --with-home"
done
# A symlink in the project dir is never followed into the archive.
d="$(mktemp -d)"; ln -s /etc/hostname "$d/hosts.extra"
[ -z "$(export_project_files "$d" 1)" ] || fail "symlinks are not exported"
rm -rf "$d"

# --- manifest round-trip, and it must never be sourced ------------------------
m="$(mktemp)"
printf 'nixenv-export=1\nproject=demo\ncreated=2026-01-02T03:04:05Z\napp_mount=/srv/app\nsource_uid=501\n' > "$m"
assert_eq "$(manifest_get "$m" nixenv-export)" "1"        "reads the marker"
assert_eq "$(manifest_get "$m" project)"       "demo"     "reads the project"
assert_eq "$(manifest_get "$m" app_mount)"     "/srv/app" "reads a value with slashes"
assert_eq "$(manifest_get "$m" missing)"       ""         "absent key is empty"
manifest_get /nonexistent-manifest key >/dev/null 2>&1 \
  && fail "manifest_get must fail on a missing file"
# A manifest comes out of an untrusted archive: sourcing it would execute it.
if printf '%s' "$body" | grep -nE '^\s*(\.|source) .*manifest'; then
  fail "the manifest must be parsed, never sourced"
fi

# --- an untrusted project name must be validated before it becomes a path -----
assert_contains "$imp" 'invalid project name from archive' "rejects path-ish names"
assert_contains "$imp" '*[!a-zA-Z0-9._-]*'                 "rejects odd characters"
assert_contains "$imp" '--no-same-owner'      "extraction ignores archived ownership"

# --- the uid remap is the thing that makes cross-machine import work ----------
assert_contains "$imp" 'chown -R ' "restored volumes are chowned"
assert_contains "$imp" '-u 0'      "restore runs as root so it can chown"
assert_contains "$imp" 'write_passwd_files' "regenerates the user db for THIS uid"
assert_contains "$imp" 'project_port'       "assigns a port here, not the exported one"

# --- the home volume is OPT-IN: a default archive holds no secrets ------------
# It carries ~/.ssh and ~/.git-credentials, so shipping it by default would make
# every backup a credential leak.
assert_contains "$exp" '--with-home'            "has an opt-in flag"
assert_contains "$exp" 'vols="app databases"'   "default excludes home"
assert_contains "$exp" 'vols="app home databases"' "--with-home includes it"
assert_contains "$exp" 'echo "home=$with_home"' "manifest records the choice"
# The secrets warning must fire ONLY when home is actually in there, or it is
# noise that gets ignored the one time it matters.
printf '%s' "$exp" | grep -q 'if \[ "$with_home" = 1 \]; then' \
  || fail "the SECRET warning is not conditional on --with-home"

# --- import must rebuild a usable home when the archive has none --------------
assert_contains "$imp" 'seed_project_home'     "reseeds dotfiles"
assert_contains "$imp" 'configure_git_identity' "asks for a git identity"
assert_contains "$imp" 'ssh-keygen'            "says how to get an ssh key back"
# Ordering: the seed must land BEFORE ensure_volumes copies it into the volume.
seed_ln="$(printf '%s\n' "$imp" | code_only | grep -n 'seed_project_home' | cut -d: -f1 | head -1)"
ev_ln="$(printf '%s\n' "$imp"   | code_only | grep -n 'ensure_volumes'    | cut -d: -f1 | head -1)"
[ "$seed_ln" -lt "$ev_ln" ] \
  || fail "home must be seeded before ensure_volumes, or the volume is seeded empty"

# seed_project_home is SHARED with init — one definition, so a skeleton change
# reaches both paths.
assert_contains "$body" 'seed_project_home() {' "the helper exists"
n="$(printf '%s' "$body" | grep -c 'seed_project_home "$pdir"')"
[ "$n" -ge 2 ] || fail "seed_project_home should be used by both init and import (found $n)"

# --- export refuses on a live project (a live DB tars crash-consistent) -------
assert_contains "$exp" 'container_running' "checks whether it is running"
assert_contains "$exp" 'crash-consistent'  "explains why that matters"
assert_contains "$exp" '--force'           "has an explicit override"
# ...and it must warn about the secrets it just archived.
assert_contains "$exp" '.git-credentials' "warns the archive holds credentials"

# --- a token in the APP volume leaks even without --with-home ----------------
# https://user:token@host is written verbatim into .git/config, and the app
# volume is in EVERY archive — so this is the hole --with-home does not close.
assert_contains "$body" 'app_git_embedded_creds() {' "can detect embedded creds"
assert_contains "$body" 'app_scrub_git_creds() {'    "can remove them"
assert_contains "$exp" 'app_git_embedded_creds' "export checks for them"
assert_contains "$exp" 'would leak them'       "export refuses with an explanation"
assert_contains "$exp" 'git remote set-url'    "export says how to fix it"
assert_contains "$imp" 'app_scrub_git_creds'   "import scrubs old archives"
# The reported line must be masked — printing the token defeats the point.
assert_contains "$exp" ':***@' "the offending line is masked in the error"
# ssh://git@host is a username, not a secret, and must survive.
scrub="$(printf '%s' "$body" | sed -n '/^app_scrub_git_creds()/,/^}/p')"
assert_contains "$scrub" 'https?://' "scrubbing is limited to http(s) URLs"

# --- clobbering an existing project is as destructive as `delete` ------------
# The restore wipes each volume before untarring, so --force here destroys data.
# `delete` confirms; this must too.
assert_contains "$imp" 'already exists ($src_of_name)' "says where the name came from"
assert_contains "$imp" 'the name you gave'   "distinguishes an explicit name"
assert_contains "$imp" 'from the archive'    "...from the manifest's name"
assert_contains "$imp" 'a-different-name'    "offers a different name"
assert_contains "$imp" "delete \$name"       "offers deleting first"
assert_contains "$imp" 'will REPLACE its app/databases volumes' "--force warns"
assert_contains "$imp" 'Proceed? [y/N]'      "--force confirms before destroying"
assert_contains "$imp" 'assume_yes'          "--yes exists for scripting"
# The abort path must clean up its temp dir, not leak it.
printf '%s' "$imp" | grep -q 'Aborted — nothing changed; rm -rf' \
  || printf '%s' "$imp" | grep -q 'Aborted — nothing changed"; rm -rf' \
  || fail "the abort path must remove the staging dir"

# --- helpers run in the BARE runtime image: no nix tools available -----------
# debian:stable-slim has coreutils/sed/grep and nothing else — git, zsh and
# socat all come from the nix store, which these helpers do NOT mount. A `git`
# call here fails silently and the caller sees an empty string, which is exactly
# how the import credential prompt came to be skipped for an https remote.
for h in app_git_remote app_git_embedded_creds app_scrub_git_creds; do
  fn="$(printf '%s' "$body" | sed -n "/^$h()/,/^}/p")"
  assert_not_contains "$fn" 'NIX_VOLUME' "$h does not mount the store (by design)"
  printf '%s' "$fn" | code_only | grep -qE '(^|[^a-z_])git ' \
    && fail "$h invokes git, which is absent from $RUNTIME_IMAGE — parse the file instead"
done
assert_contains "$body" 'sed -n "/^\[remote \"origin\"\]/' "origin URL is parsed, not queried"

# --- import restores https auth into the fresh home --------------------------
assert_contains "$imp" 'app_git_remote'           "reads the origin URL"
assert_contains "$imp" 'configure_git_credentials' "prompts for a token"
assert_contains "$imp" 'sync_home_files'          "pushes them into the home volume"
# ensure_volumes has already seeded the home volume by then, so writing only to
# the host-side seed would never reach the container.
sh_ln="$(printf '%s\n' "$imp" | code_only | grep -n 'sync_home_files' | cut -d: -f1 | head -1)"
ev_ln="$(printf '%s\n' "$imp" | code_only | grep -n 'ensure_volumes'  | cut -d: -f1 | head -1)"
[ "$sh_ln" -gt "$ev_ln" ] || fail "sync_home_files must run AFTER ensure_volumes"

# --- the shared store must NOT be in the archive (GBs, and reproducible) -----
for v in NIX_VOLUME nix/var/nix/profiles; do
  assert_not_contains "$exp" "$v" "export must not touch the shared store ($v)"
done

# --- default archive name is stable and collision-resistant -------------------
n="$(export_archive_default demo)"
case "$n" in
  nixenv-demo-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar) ;;
  *) fail "unexpected default archive name: $n";;
esac

# --- progress: a multi-GB volume must not look like a hang --------------------
# Counting happens in awk, not a bash read loop, or the meter becomes the
# bottleneck on a 200k-file volume.
pc="$(printf '%s' "$body" | sed -n '/^progress_count()/,/^}/p')"
assert_contains "$pc" 'awk'   "counts in awk, not a shell loop"
assert_contains "$pc" '/dev/stderr' "reports on stderr, leaving stdout for data"
assert_contains "$pc" '-t 2'  "detects a TTY"
# (comments stripped — the comment there names the anti-pattern on purpose)
printf '%s' "$pc" | code_only | grep -q '\[ -t 2 \] &&' \
  && fail "uses \`[ -t 2 ] &&\` — a false test trips set -e"

# Counts every line, and the total is what's reported.
assert_eq "$(seq 1 1000 | progress_count lbl 2>&1 >/dev/null | tr -d '\r' | tail -1)" \
          "   lbl… 1000 files" "reports the final count"
assert_eq "$(: | progress_count lbl 2>&1 >/dev/null | tr -d '\r')" \
          "   lbl… 0 files" "empty input still terminates"
# Non-TTY must not spam: periodic lines only, not one per file.
lines="$(seq 1 20000 | progress_count lbl 2>&1 >/dev/null | wc -l | tr -d ' ')"
[ "$lines" -le 10 ] || fail "non-TTY progress printed $lines lines (should be periodic)"

# NIXENV_PROGRESS=0 must silence it AND still drain stdin, or tar would block on
# a full pipe.
out="$(NIXENV_PROGRESS=0 seq 1 5000 | NIXENV_PROGRESS=0 progress_count lbl 2>&1)"
assert_eq "$out" "" "NIXENV_PROGRESS=0 is silent"
assert_contains "$pc" 'cat >/dev/null' "quiet mode still drains stdin"

# --- the tar calls must be verbose, or there is nothing to count --------------
assert_contains "$exp" 'tar -C /src -cvzf' "export lists files (-v) for progress"
assert_contains "$imp" 'tar -C /dst -xvzf' "import lists files (-v) for progress"
assert_contains "$exp" 'progress_count "archiving' "export shows progress"
assert_contains "$imp" 'progress_count "restoring' "import shows progress"
# stderr must NOT be discarded: "file changed as we read it" matters on --force.
printf '%s' "$exp" | grep -q 'cvzf.*2>/dev/null' \
  && fail "export hides tar's stderr — real warnings would vanish"

# --- both commands are reachable ---------------------------------------------
for c in export import; do
  printf '%s' "$body" | grep -qE "^ *$c\\) *cmd_$c " || fail "'$c' is not dispatched"
done
help="$("$REPO_DIR/nixenv.sh" --help)"
assert_contains "$help" "export <project>" "help documents export"
assert_contains "$help" "import <file>"    "help documents import"
