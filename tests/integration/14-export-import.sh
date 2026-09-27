#!/usr/bin/env bash
# export → import round-trip: data survives, and the machine-specific state is
# regenerated rather than restored.
source "$(dirname "$0")/../lib.sh" it
sweep; trap 'sweep; rm -f /tmp/nxt-export.tar' EXIT
require_store

mkproj src --unrestricted
nx run src >/dev/null

# Put identifiable data in all three volumes.
dexec src sh -lc 'echo hello-app > "$NIXENV_APP_MOUNT/marker.txt"'
dexec src sh -lc 'mkdir -p /databases/pgsql && echo hello-db > /databases/pgsql/marker.txt'
dexec src sh -lc 'echo hello-home > "$HOME/marker.txt"'
src_port="$(cat "$PROJECTS_DIR/src/port")"

# --- export refuses while the project is running ------------------------------
out="$(nx export src /tmp/nxt-export.tar 2>&1 || true)"
assert_contains "$out" "stop it first" "refuses to export a running project"
[ -f /tmp/nxt-export.tar ] && fail "wrote an archive despite refusing"

nx stop src >/dev/null
nx export src /tmp/nxt-export.tar >/dev/null || fail "export failed"
[ -s /tmp/nxt-export.tar ] || fail "archive is empty"

# --- the archive must carry the volumes and a manifest, and NOT the nix store -
names="$(tar -tf /tmp/nxt-export.tar)"
for e in nixenv-export/manifest nixenv-export/volumes/app.tar.gz \
         nixenv-export/volumes/databases.tar.gz; do
  printf '%s\n' "$names" | grep -qx "$e" || fail "archive is missing $e"
done
# The home volume holds ssh keys and git credentials: opt-in only.
printf '%s\n' "$names" | grep -q 'volumes/home.tar.gz' \
  && fail "default export leaked the home volume (secrets!)"
printf '%s\n' "$names" | grep -q 'nix/store' && fail "archive contains the nix store!"
# Machine-specific files must not be in there.
for e in passwd shadow port; do
  printf '%s\n' "$names" | grep -q "meta/$e\$" && fail "archive carries machine state: $e"
done

# --- import under a new name --------------------------------------------------
# Identity comes from env here so the test doesn't depend on the runner's global
# git config (configure_git_identity only prompts when stdin is a TTY).
GIT_USER_NAME="Test User" GIT_USER_EMAIL="test@example.com" \
  nx import /tmp/nxt-export.tar dst >/dev/null || fail "import failed"
[ -d "$PROJECTS_DIR/dst" ] || fail "import created no project dir"

# Data survived, in all three volumes.
nx run dst >/dev/null
assert_eq "$(dexec dst sh -lc 'cat "$NIXENV_APP_MOUNT/marker.txt"')" "hello-app" "app volume restored"
assert_eq "$(dexec dst sh -lc 'cat /databases/pgsql/marker.txt')"    "hello-db"  "databases restored"
# home was NOT exported, so it is reseeded — the marker must be gone but the
# dotfiles present, and no credentials created.
dexec dst sh -lc 'test ! -e "$HOME/marker.txt"' || fail "home volume came across despite the default"
dexec dst sh -lc 'test -f "$HOME/.zshrc" && test -d "$HOME/.ssh"' || fail "home was not reseeded"
dexec dst sh -lc 'test ! -e "$HOME/.git-credentials"' || fail "reseeded home has credentials"
assert_eq "$(dexec dst sh -lc 'stat -c %a "$HOME/.ssh"')" "700" "reseeded .ssh perms"

# Restored files must be writable — this is the uid-remap guarantee.
dexec dst sh -lc 'echo more >> "$NIXENV_APP_MOUNT/marker.txt"' \
  || fail "restored app volume is not writable (chown did not happen)"

# --- machine-specific state is REGENERATED, not copied ------------------------
dst_port="$(cat "$PROJECTS_DIR/dst/port")"
[ "$dst_port" != "$src_port" ] || fail "import reused the exported port"
assert_file "$PROJECTS_DIR/dst/passwd" "regenerated the user db"
grep -q ":$(id -u):" "$PROJECTS_DIR/dst/passwd" || fail "passwd does not carry our uid"
assert_file "$PROJECTS_DIR/dst/ssh/config" "wrote a host ssh config"
grep -q "Port $dst_port" "$PROJECTS_DIR/dst/ssh/config" || fail "ssh config has the wrong port"
grep -q "test@example.com" "$PROJECTS_DIR/dst/home/.gitconfig.identity" \
  || fail "import did not write a git identity into the fresh home"

# --- --with-home round-trips the home volume ---------------------------------
nx stop src >/dev/null 2>&1 || true
nx export src /tmp/nxt-export-home.tar --with-home >/dev/null || fail "--with-home export failed"
tar -tf /tmp/nxt-export-home.tar | grep -q 'volumes/home.tar.gz' \
  || fail "--with-home did not include the home volume"
nx import /tmp/nxt-export-home.tar withhome >/dev/null || fail "--with-home import failed"
nx run withhome >/dev/null
assert_eq "$(dexec withhome sh -lc 'cat "$HOME/marker.txt"')" "hello-home" "home restored with --with-home"
rm -f /tmp/nxt-export-home.tar

# --- importing over an existing project needs --force -------------------------
out="$(nx import /tmp/nxt-export.tar dst 2>&1 || true)"
assert_contains "$out" "already exists" "refuses to clobber an existing project"

# --- a non-archive is rejected, not half-imported -----------------------------
echo "not a tar" > /tmp/nxt-export-bad.tar
out="$(nx import /tmp/nxt-export-bad.tar other 2>&1 || true)"
rm -f /tmp/nxt-export-bad.tar
[ -d "$PROJECTS_DIR/other" ] && fail "created a project from a bogus archive"
case "$out" in *"could not extract"*|*"not a nixenv export"*) ;;
  *) fail "unhelpful error for a bogus archive: $out";; esac
