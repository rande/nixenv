#!/usr/bin/env bash
# write_caddyfile: routing regex, forwarded headers, streaming, tls modes.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$PROXY_DIR"

write_caddyfile 0
cf="$(cat "$PROXY_DIR/Caddyfile")"
assert_contains "$cf" "http_port 8080"
assert_contains "$cf" "https_port 8443"
assert_contains "$cf" "*.$PROXY_DOMAIN"
assert_contains "$cf" "tls internal" "internal CA mode"
assert_contains "$cf" '^(.+)-([0-9]+)\.nixenv\.localhost(:[0-9]+)?$' "route regex"
assert_contains "$cf" "reverse_proxy ${CONTAINER_PREFIX}-{re.route.1}:{re.route.2}" "dynamic upstream uses container prefix"
assert_contains "$cf" "header_up X-Forwarded-Proto https"
assert_contains "$cf" "header_up X-Forwarded-Port 443"
assert_contains "$cf" "header_up X-Real-IP"
assert_contains "$cf" "flush_interval -1" "streaming enabled"
assert_contains "$cf" "respond" "502 fallback"

write_caddyfile 1
cf="$(cat "$PROXY_DIR/Caddyfile")"
assert_contains "$cf" "tls /certs/wildcard.pem /certs/wildcard-key.pem" "mkcert mode"
assert_not_contains "$cf" "tls internal" "no internal CA in cert mode"
