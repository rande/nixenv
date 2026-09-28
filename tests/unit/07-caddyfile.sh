#!/usr/bin/env bash
# write_caddyfile: routing regex, forwarded headers, streaming, tls modes,
# and the cross-project guard.
source "$(dirname "$0")/../lib.sh"
source_nixenv

rm -rf "$PROXY_DIR"
rm -rf "$PROJECTS_DIR"; mkdir -p "$PROJECTS_DIR"
EGRESS_SUBNETS=""

write_caddyfile 0
cf="$(cat "$PROXY_DIR/Caddyfile")"
# Standard ports in-container (proxy runs with ip_unprivileged_port_start=0), so
# https://<project>-<port>.<domain>/ works from inside containers with no suffix.
assert_contains "$cf" "http_port 80"
assert_contains "$cf" "https_port 443"
assert_contains "$cf" "*.$PROXY_DOMAIN"
assert_contains "$cf" "tls internal" "internal CA mode"
# Only project-name characters, never (.+).
assert_contains "$cf" '^([a-zA-Z0-9_-]+)-([0-9]+)\.nixenv\.localhost(:[0-9]+)?$' "route regex"
assert_not_contains "$cf" '(.+)' "no catch-all project group"
assert_contains "$cf" "reverse_proxy @route ${CONTAINER_PREFIX}-{re.route.1}:{re.route.2}" "dynamic upstream uses container prefix"
assert_contains "$cf" "header_up X-Forwarded-Proto https"
assert_contains "$cf" "header_up X-Forwarded-Port 443"
assert_contains "$cf" "header_up X-Real-IP"
assert_contains "$cf" "flush_interval -1" "streaming enabled"
assert_contains "$cf" "respond \"nixenv proxy: no route" "502 fallback"
assert_not_contains "$cf" "@xproj_" "no restricted projects → no guards"

write_caddyfile 1
cf="$(cat "$PROXY_DIR/Caddyfile")"
assert_contains "$cf" "tls /certs/wildcard.pem /certs/wildcard-key.pem" "mkcert mode"
assert_not_contains "$cf" "tls internal" "no internal CA in cert mode"

# --- Per-project source guard -----------------------------------------
mkdir -p "$PROJECTS_DIR/alpha" "$PROJECTS_DIR/beta" "$PROJECTS_DIR/gamma" "$PROJECTS_DIR/my-app"
EGRESS_SUBNETS="alpha 10.89.1.0/24
beta 10.89.2.0/24
my-app 10.89.4.0/24
"
# beta accepts alpha; gamma accepts everyone; injection attempts are dropped.
printf '# peers\nalpha\n' > "$PROJECTS_DIR/beta/accept-from"
printf '*\n' > "$PROJECTS_DIR/gamma/accept-from"
printf 'x)|.*(\nmy-app\n' > "$PROJECTS_DIR/alpha/accept-from"

write_caddyfile 0
cf="$(cat "$PROXY_DIR/Caddyfile")"
dom='\.nixenv\.localhost(:[0-9]+)?$'
assert_contains "$cf" "remote_ip 10.89.1.0/24" "alpha identified by its subnet"
assert_contains "$cf" "not header_regexp Host ^(alpha|beta|gamma)-[0-9]+$dom" "alpha: self + accepting peers"
assert_contains "$cf" "not header_regexp Host ^(beta|gamma)-[0-9]+$dom" "beta: self + gamma(*) only"
assert_contains "$cf" "not header_regexp Host ^(my-app|alpha|gamma)-[0-9]+$dom" "my-app: alpha lists it"
assert_contains "$cf" "respond @xproj_alpha " "alpha deny line"
assert_contains "$cf" "respond @xproj_my_app " "matcher name sanitised"
assert_contains "$cf" '" 403' "denied with 403"
assert_not_contains "$cf" '.*(' "invalid accept-from entry never reaches the config"
# gamma is unrestricted (not in EGRESS_SUBNETS): no guard of its own.
assert_not_contains "$cf" "@xproj_gamma" "unrestricted projects are not guarded"

# Denies must sit INSIDE the ordered 'route' block, BEFORE the reverse_proxy —
# otherwise Caddy's directive sorting could proxy first.
route_ln="$(printf '%s\n' "$cf" | grep -n '^	route {' | cut -d: -f1)"
deny_ln="$(printf '%s\n' "$cf" | grep -n 'respond @xproj_alpha' | cut -d: -f1)"
rp_ln="$(printf '%s\n' "$cf" | grep -n 'reverse_proxy @route' | cut -d: -f1)"
[ -n "$route_ln" ] && [ "$route_ln" -lt "$deny_ln" ] && [ "$deny_ln" -lt "$rp_ln" ] \
  || fail "guard must be inside route{} and before reverse_proxy ($route_ln/$deny_ln/$rp_ln)"
assert_not_contains "$cf" "handle @route" "no unordered handle blocks"

# Behaviour: the generated guard regex, applied the way Caddy would. Host
# requests (no matching subnet) are never guarded, so only origins matter here.
guard_re() { printf '%s\n' "$cf" | awk -v id="$1" '
  $0 ~ "@xproj_" id " \\{" {f=1} f && /not header_regexp Host/ {print $4; exit}'; }
allowed() { printf '%s' "$2" | grep -Eq "$(guard_re "$1")"; }
allowed alpha  "alpha-3000.nixenv.localhost"      || fail "alpha → itself must pass"
allowed alpha  "beta-8000.nixenv.localhost:8443"  || fail "alpha → beta (accept-from) must pass"
allowed beta   "alpha-3000.nixenv.localhost"      && fail "beta → alpha must be denied"
allowed beta   "my-app-80.nixenv.localhost"       && fail "beta → my-app must be denied"
# Hyphenated names can't be used to smuggle a target past the anchor.
allowed alpha  "alpha-x-3000.nixenv.localhost"    && fail "alpha → 'alpha-x' must be denied"
allowed my_app "my-app-80.nixenv.localhost"       || fail "my-app → itself must pass"
allowed my_app "beta-80.nixenv.localhost"         && fail "my-app → beta must be denied"

# accept-from travels with an export (project config, machine independent).
case " $EXPORT_META_FILES " in *" accept-from "*) ;;
  *) fail "accept-from should be in EXPORT_META_FILES";; esac

# --- relays: bound to the proxy's primary address ------------------------------
body="$(cat "$REPO_DIR/nixenv.sh")"
eg_fn="$(printf '%s' "$body" | sed -n '/^write_egress_configs()/,/^}/p' | code_only)"
assert_contains "$eg_fn" 'reuseaddr\${RELAY_BIND:+,bind=\$RELAY_BIND}' "relays bind to RELAY_BIND"
assert_contains "$eg_fn" 'RELAY_BIND="\$(hostname -I' "start.sh detects the primary address"

# proxy up generates egress BEFORE the Caddyfile (EGRESS_SUBNETS dependency).
px_fn="$(printf '%s' "$body" | sed -n '/^cmd_proxy()/,/^}/p' | code_only)"
e_ln="$(printf '%s\n' "$px_fn" | grep -n 'write_egress_configs' | head -1 | cut -d: -f1)"
c_ln="$(printf '%s\n' "$px_fn" | grep -n 'write_caddyfile' | head -1 | cut -d: -f1)"
[ "$e_ln" -lt "$c_ln" ] || fail "write_egress_configs must run before write_caddyfile"
assert_contains "$px_fn" "caddy\" reload" "proxy reload hot-reloads caddy"
true
