#!/usr/bin/env bash
# <project>/limits → --memory/--cpus on the project container (RUN-16).
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$PROJECTS_DIR"
mkdir -p "$PROJECTS_DIR/plain" "$PROJECTS_DIR/lim"
resolve_engine() { return 1; }   # never touch a real engine

# --- validation ---------------------------------------------------------------
for v in 1 512m 4g 4G 1024k 2147483648; do
  valid_limit memory "$v" || fail "memory '$v' should be valid"
done
for v in "" 0 0g g 4gb 4.5g -1 4g1 "4 g" 1234567890123g '$(id)'; do
  if valid_limit memory "$v"; then fail "memory '$v' should be refused"; fi
done
for v in 1 2 0.5 1.25 16; do
  valid_limit cpus "$v" || fail "cpus '$v' should be valid"
done
for v in "" 0 0.0 .5 1. 1.2.3 -1 abc '2;id'; do
  if valid_limit cpus "$v"; then fail "cpus '$v' should be refused"; fi
done
if valid_limit swap 1g; then fail "unknown key refused"; fi

# --- no file: no flags, empty summary -------------------------------------------
assert_eq "$(project_limit_args plain)" "" "no file → no flags"
assert_eq "$(project_limits_summary plain)" "" "no file → empty summary"

# --- file → flags; comments, blanks, last value wins; invalid ignored -----------
printf '# note\nmemory = 2g\ncpus=1\n\nmemory=4g  # later wins\ncpus=lots\n' > "$PROJECTS_DIR/lim/limits"
assert_eq "$(project_limit_args lim 2>/dev/null | tr '\n' ' ')" "--memory=4g " "invalid cpus ignored"
assert_contains "$(project_limit_args lim 2>&1 >/dev/null)" "invalid cpus limit 'lots'" "invalid value warned"
printf 'memory=4g\ncpus=1.5\n' > "$PROJECTS_DIR/lim/limits"
assert_eq "$(project_limit_args lim | tr '\n' ' ')" "--memory=4g --cpus=1.5 " "both flags"
assert_eq "$(project_limits_summary lim)" "memory=4g cpus=1.5" "summary"

# --- cmd_limits writes, merges, clears, refuses bad input -------------------------
out="$(cmd_limits lim cpus=2 2>&1)"
assert_eq "$(project_limits_summary lim)" "memory=4g cpus=2" "set one key, keep the other"
cmd_limits lim memory= >/dev/null 2>&1
assert_eq "$(project_limits_summary lim)" "cpus=2" "empty value removes one key"
cmd_limits lim --memory=512m >/dev/null 2>&1
assert_eq "$(project_limits_summary lim)" "memory=512m cpus=2" "--key=value accepted"
if (cmd_limits lim memory=lots) >/dev/null 2>&1; then fail "invalid memory refused"; fi
if (cmd_limits lim swap=1g) >/dev/null 2>&1; then fail "unknown key refused"; fi
if (cmd_limits lim bogus) >/dev/null 2>&1; then fail "bare word refused"; fi
assert_eq "$(project_limits_summary lim)" "memory=512m cpus=2" "a refused call changes nothing"
assert_contains "$(cmd_limits lim 2>&1)" "memory=512m cpus=2" "no argument shows the limits"
cmd_limits lim off >/dev/null 2>&1
assert_no_file "$PROJECTS_DIR/lim/limits" "off removes the file"
if (cmd_limits nope memory=1g) >/dev/null 2>&1; then fail "unknown project refused"; fi
ln -s /etc/passwd "$PROJECTS_DIR/lim/limits"
if (cmd_limits lim memory=1g) >/dev/null 2>&1; then fail "symlinked limits refused"; fi
rm -f "$PROJECTS_DIR/lim/limits"

# --- cmd_run wiring: before extra-parameters, labelled, symlink-checked ----------
body="$(sed -n '/^cmd_run() {/,/^}/p' "$NIXENV_SH" | code_only)"
lim_line="$(printf '%s\n' "$body" | grep -n 'limits\[@\]' | head -1 | cut -d: -f1)"
ext_line="$(printf '%s\n' "$body" | grep -n 'extra_args\[@\]+' | head -1 | cut -d: -f1)"
[ -n "$lim_line" ] && [ -n "$ext_line" ] || fail "cmd_run passes both limits and extra_args"
[ "$lim_line" -lt "$ext_line" ] || fail "limits must come BEFORE extra_args so extra-parameters wins"
assert_contains "$body" '--label "$LIMITS_LABEL=$limsum"' "the container records its limits"
assert_contains "$body" 'extra-parameters app_mount limits; do' "a symlinked limits file is refused"
rec="$(sed -n '/^container_needs_recreate() {/,/^}/p' "$NIXENV_SH" | code_only)"
assert_contains "$rec" 'LIMITS_LABEL' "a running container with other limits is reported"

# --- import keeps only valid lines -------------------------------------------------
imp="$(sed -n '/^import_meta_files() {/,/^}/p' "$NIXENV_SH" | code_only)"
assert_contains "$imp" 'limits)' "import re-validates limits"
assert_contains "$imp" 'if valid_limit "${line%%=*}"' "with valid_limit"
exit 0
