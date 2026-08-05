#!/usr/bin/env bash
# =============================================================================
# tests/run.sh — run the nixenv test suite (one bash file per test)
#   ./tests/run.sh                # unit tests only (no engine needed)
#   ./tests/run.sh integration    # integration tests (docker; dedicated env!)
#   ./tests/run.sh all            # both
#   ./tests/run.sh <file>...      # specific test files
# Exit code: number of failed tests (0 = green).
# =============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
c_g='\033[1;32m'; c_r='\033[1;31m'; c_y='\033[1;33m'; c_0='\033[0m'

files=()
case "${1:-unit}" in
  unit)         files=("$TESTS_DIR"/unit/*.sh);;
  integration)  files=("$TESTS_DIR"/integration/*.sh);;
  all)          files=("$TESTS_DIR"/unit/*.sh "$TESTS_DIR"/integration/*.sh);;
  *)            files=("$@");;
esac

pass=0; failed=0; skipped=0; failed_names=()
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "no such test: $f"; failed=$((failed+1)); continue; }
  name="$(basename "$(dirname "$f")")/$(basename "$f")"
  start=$(date +%s)
  out="$(bash "$f" 2>&1)"; rc=$?
  dur=$(( $(date +%s) - start ))
  case "$rc" in
    0)  printf "${c_g}PASS${c_0}  %-40s (%ss)\n" "$name" "$dur"; pass=$((pass+1));;
    77) printf "${c_y}SKIP${c_0}  %-40s %s\n" "$name" "$(printf '%s' "$out" | tail -1)"; skipped=$((skipped+1));;
    *)  printf "${c_r}FAIL${c_0}  %-40s (%ss)\n" "$name" "$dur"
        printf '%s\n' "$out" | sed 's/^/      /' | tail -15
        failed=$((failed+1)); failed_names+=("$name");;
  esac
done

echo "──────────────────────────────────────────────"
printf "pass: %d   fail: %d   skip: %d\n" "$pass" "$failed" "$skipped"
[ "$failed" -gt 0 ] && printf "${c_r}failed:${c_0} %s\n" "${failed_names[*]}"
exit "$failed"
