#!/usr/bin/env bash
# specs/: one rule per file, well-formed, indexed, loaded via .claude/rules/,
# and pointing only at things that exist — so the specs can't silently rot.
source "$(dirname "$0")/../lib.sh"

cd "$REPO_DIR" || fail "repo dir"
[ -f specs/README.md ] || fail "specs/README.md index exists"
tracked="$(git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
[ -n "$tracked" ] || skip "not a git checkout"

prefix_for() {
  case "$1" in
    core) echo CORE;; toolchain) echo TOOL;; runtime) echo RUN;; ssh) echo SSH;;
    networking) echo NET;; egress) echo EGR;; capture) echo CAP;; deploy) echo DEP;;
    export) echo EXP;; templates) echo TPL;; release) echo REL;; dev) echo DEV;;
    testing) echo TEST;; *) echo "?";;
  esac
}

ids=""
n=0
for f in specs/*/*.md; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  area="$(basename "$(dirname "$f")")"
  # frontmatter = lines between the first two '---'
  fm="$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 {print}' "$f")"
  [ -n "$fm" ] || fail "$f: missing frontmatter"
  id="$(printf '%s\n' "$fm" | sed -n 's/^id: *//p')"
  title="$(printf '%s\n' "$fm" | sed -n 's/^title: *//p')"
  farea="$(printf '%s\n' "$fm" | sed -n 's/^area: *//p')"
  [ -n "$id" ] && [ -n "$title" ] || fail "$f: id and title are required"
  assert_eq "$farea" "$area" "$f: area matches its folder"
  case "$id" in "$(prefix_for "$area")"-[0-9][0-9]) ;; *) fail "$f: id '$id' must be $(prefix_for "$area")-NN";; esac
  num="$(basename "$f" | cut -c1-3)"
  assert_eq "${id##*-}" "${num#0}" "$f: id number matches the file number"
  case " $ids " in *" $id "*) fail "duplicate spec id $id";; esac
  ids="$ids $id"
  grep -q "^# $id: " "$f" || fail "$f: heading must start with '# $id: '"
  for s in '## Rule' '## Why' '## How'; do
    grep -qx "$s" "$f" || fail "$f: missing section '$s'"
  done

  # applies-to: non-empty, and every glob matches at least one repo file
  globs="$(printf '%s\n' "$fm" | awk '/^applies-to:/ {on=1; next} /^[^ ]/ {on=0} on && /^  - / {sub(/^  - /, ""); gsub(/"/, ""); print}')"
  [ -n "$globs" ] || fail "$f: applies-to is empty"
  while IFS= read -r g; do
    hit=0
    while IFS= read -r t; do
      # shellcheck disable=SC2254
      case "$t" in $g) hit=1; break;; esac
    done <<EOF
$tracked
EOF
    [ "$hit" = 1 ] || fail "$f: applies-to '$g' matches no file in the repo"
  done <<EOF
$globs
EOF

  # enforced-by: every path exists
  enf="$(printf '%s\n' "$fm" | awk '/^enforced-by:/ {on=1; next} /^[^ ]/ {on=0} on && /^  - / {sub(/^  - /, ""); print}')"
  if [ -n "$enf" ]; then
    while IFS= read -r e; do
      [ -e "$e" ] || fail "$f: enforced-by '$e' does not exist"
    done <<EOF
$enf
EOF
  fi

  # indexed, and loaded through its area's rules file
  rel="${f#specs/}"
  grep -qF "]($rel)" specs/README.md || fail "$f is not linked from specs/README.md"
  grep -qF "@../../$f" ".claude/rules/$area.md" 2>/dev/null \
    || fail "$f is not imported by .claude/rules/$area.md"
done
[ "$n" -gt 50 ] || fail "expected the full spec set, found $n files"

# rules files point only at specs that exist
for r in .claude/rules/*.md; do
  for p in $(grep -o '@\.\./\.\./specs/[^ ]*\.md' "$r" | sed 's#^@\.\./\.\./##'); do
    [ -f "$p" ] || fail "$r imports missing $p"
  done
done
# the index links only specs that exist
for p in $(grep -o '](\([a-z]*/[0-9][0-9][0-9]-[^)]*\.md\))' specs/README.md | sed 's#^](##; s#)$##'); do
  [ -f "specs/$p" ] || fail "specs/README.md links missing specs/$p"
done

# entry points
grep -qx '@AGENTS.md' CLAUDE.md || fail "CLAUDE.md imports AGENTS.md"
grep -qx '@specs/README.md' CLAUDE.md || fail "CLAUDE.md imports the specs index"
grep -q 'specs/' AGENTS.md || fail "AGENTS.md points at specs/"
echo "ok ($n specs)"
