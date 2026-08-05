#!/usr/bin/env bash
# sync-home: refreshes dotfiles into the volume, backs up, layers repo overrides.
source "$(dirname "$0")/../lib.sh" it
sweep; trap sweep EXIT
require_store

mkproj p1 --unrestricted
nx run p1 >/dev/null

# make the volume's .zshrc diverge + plant a repo override
dexec p1 sh -c 'echo "# LOCAL EDIT" >> /home/app/.zshrc'
dexec p1 sh -c 'mkdir -p /app/.nixenv/home && echo OVERRIDE > /app/.nixenv/home/.custom-rc'

printf 'y\n' | nx sync-home p1 >/dev/null

involume nxt_p1_home 'test -f /v/.custom-rc' || fail "repo override not applied"
assert_eq "$(involume nxt_p1_home 'cat /v/.custom-rc')" "OVERRIDE"
involume nxt_p1_home 'ls /v/.nixenv/home-backups/*/.zshrc >/dev/null 2>&1' \
  || fail "overwritten .zshrc not backed up"
involume nxt_p1_home 'grep -q "LOCAL EDIT" /v/.nixenv/home-backups/*/.zshrc' \
  || fail "backup does not contain the local edit"
involume nxt_p1_home 'grep -q "LOCAL EDIT" /v/.zshrc' \
  && fail "sync-home did not refresh .zshrc" || true
