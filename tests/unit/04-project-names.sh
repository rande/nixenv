#!/usr/bin/env bash
# valid_project_name: safe charset, reserved names.
source "$(dirname "$0")/../lib.sh"
source_nixenv

for good in myapp my-app my_app APP123 a; do
  valid_project_name "$good" >/dev/null 2>&1 || fail "should accept: $good"
done
for bad in "my app" "a:b" "a/b" "app.2" "-x" "" proxy; do
  if valid_project_name "$bad" >/dev/null 2>&1; then fail "should reject: $bad"; fi
done
