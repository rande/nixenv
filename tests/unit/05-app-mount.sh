#!/usr/bin/env bash
# project_app_mount: /app default, honours <project>/app_mount.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR/p1" "$PROJECTS_DIR/p2"
assert_eq "$(project_app_mount p1)" "/app" "default"

printf '%s' "/var/www/html" > "$PROJECTS_DIR/p2/app_mount"
assert_eq "$(project_app_mount p2)" "/var/www/html" "custom"

: > "$PROJECTS_DIR/p2/app_mount"      # empty file → fall back to default
assert_eq "$(project_app_mount p2)" "/app" "empty file falls back"
