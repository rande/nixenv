#!/usr/bin/env bash
# <project>/extra-parameters appends arbitrary engine flags to the project
# container's `run`. Scaffolded empty so it is discoverable; contents verbatim.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$PROJECTS_DIR"
mkdir -p "$PROJECTS_DIR/plain" "$PROJECTS_DIR/flags" "$PROJECTS_DIR/scaffold"

# --- absent file: nothing -----------------------------------------------------
assert_eq "$(project_extra_args plain)" "" "no file → no extra flags"

# --- the scaffold is created empty, and is a no-op ----------------------------
write_extra_parameters scaffold
f="$PROJECTS_DIR/scaffold/extra-parameters"
assert_file "$f" "scaffold created when missing"
assert_eq "$(project_extra_args scaffold)" "" "scaffold contributes no flags"
# every line is a comment or blank — nothing is silently switched on
while IFS= read -r line; do
  case "$line" in ''|\#*) ;; *) fail "scaffold has a live flag: $line";; esac
done < "$f"

# --- never clobbers an existing file -----------------------------------------
printf -- '--memory=9g\n' > "$f"
write_extra_parameters scaffold
assert_eq "$(project_extra_args scaffold)" "--memory=9g" "existing file untouched"

# --- contents pass through verbatim, comments stripped, whitespace collapsed --
printf -- '# a note\n--memory=4g\n--ulimit  nofile=8192\n\n--device /dev/fuse\n' \
  > "$PROJECTS_DIR/flags/extra-parameters"
out="$(project_extra_args flags)"
assert_eq "$out" "--memory=4g --ulimit nofile=8192 --device /dev/fuse" "verbatim, normalised"
assert_not_contains "$out" "#" "comments stripped"
case "$out" in *$'\n'*) fail "must be one line (newlines break word-splitting)";; esac
# shellcheck disable=SC2086
set -- $out
assert_eq "$#" "5" "splits into 5 argv tokens"

# --- no magic presets: an @token is NOT interpreted ---------------------------
printf '@podman\n' > "$PROJECTS_DIR/flags/extra-parameters"
assert_eq "$(project_extra_args flags)" "@podman" "no preset expansion"

# --- cmd_run array-expands, and scaffolds the file ----------------------------
body="$(cat "$REPO_DIR/nixenv.sh")"
assert_contains "$body" '${extra_args[@]+"${extra_args[@]}"} \' "run uses the guarded array"
assert_contains "$body" 'write_extra_parameters "$name"' "run/init scaffold the file"
# An unquoted $(…) at the call site would re-read the file and skip the array.
if printf '%s' "$body" | grep -q '^[[:space:]]*\$(project_extra_args'; then
  fail "expanded inline at the call site instead of via the array"
fi
