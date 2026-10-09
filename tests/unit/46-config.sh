#!/usr/bin/env bash
# CORE-09: ~/.nixenv/config is parsed (never sourced), only known keys, the
# environment wins.
source "$(dirname "$0")/../lib.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$NIXENV_CONFIG" <<CFG
# comment
PROXY_BIND=100.101.102.103
export PROXY_NIP_DOMAIN="100.101.102.103.nip.io"
  PROXY_AUTOSTART = '0'
PROXY_DOMAIN=\$(touch $T/pwned)
CONTAINER_PREFIX=evil
not a setting
CFG

# Each case sources nixenv.sh in a clean subshell, as a real command would.
val() { ( unset PROXY_BIND PROXY_NIP_DOMAIN PROXY_AUTOSTART PROXY_DOMAIN
          for kv in "${@:2}"; do export "$kv"; done
          source "$NIXENV_SH" 2>"$T/err"; eval "printf '%s' \"\$$1\"" ); }

assert_eq "$(val PROXY_BIND)" "100.101.102.103" "plain KEY=VALUE"
assert_eq "$(val PROXY_NIP_DOMAIN)" "100.101.102.103.nip.io" "export prefix and double quotes"
assert_eq "$(val PROXY_AUTOSTART)" "0" "blanks around = and single quotes"
assert_eq "$(val PROXY_DOMAIN)" "\$(touch $T/pwned)" "values are text"
assert_no_file "$T/pwned" "the file is never executed"
assert_eq "$(val CONTAINER_PREFIX CONTAINER_PREFIX=nxt)" "nxt" "unknown keys are not read"
assert_contains "$(cat "$T/err")" "unknown setting 'CONTAINER_PREFIX'" "unknown key warns"
assert_contains "$(cat "$T/err")" "not KEY=VALUE" "malformed line warns"

# The environment wins, even when set to "" (PROXY_NIP_DOMAIN= turns nip.io off).
assert_eq "$(val PROXY_BIND PROXY_BIND=10.0.0.1)" "10.0.0.1" "env overrides the file"
assert_eq "$(val PROXY_NIP_DOMAIN PROXY_NIP_DOMAIN=)" "" "an empty env value still wins"

# No file: defaults, no output.
rm -f "$NIXENV_CONFIG"
assert_eq "$(val PROXY_NIP_DOMAIN)" "127.0.0.1.nip.io" "default without a file"
assert_eq "$(cat "$T/err")" "" "no file, no warning"

# Every key read from the file is one the script really uses.
source_nixenv
code="$(code_only < "$NIXENV_SH")"   # a variable: grep -q in a pipe trips pipefail
for k in $NIXENV_CONFIG_KEYS; do
  assert_contains "$code" "\${$k" "$k is a setting nixenv.sh uses"
done
true
