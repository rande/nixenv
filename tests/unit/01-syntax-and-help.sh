#!/usr/bin/env bash
# The script parses, --help renders, and every dispatched command has a function.
source "$(dirname "$0")/../lib.sh"

bash -n "$NIXENV_SH" || fail "bash -n"

out="$(nx --help)" || fail "--help exited non-zero"
for word in init run ssh shell expose host proxy restrict allow egress \
            sync-home projects update status clean install uninstall delete; do
  assert_contains "$out" "$word" "help mentions '$word'"
done

# Every cmd_* referenced in the dispatch table exists.
missing="$(awk '/case "\$cmd" in/,/esac/' "$NIXENV_SH" | grep -oE 'cmd_[a-z_]+' | sort -u | while read -r fn; do
  grep -q "^${fn}()" "$NIXENV_SH" || echo "$fn"
done)"
[ -z "$missing" ] || fail "dispatched but undefined: $missing"
