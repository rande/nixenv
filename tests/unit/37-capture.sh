#!/usr/bin/env bash
# 'nixenv capture' + the egress container split: squid routes captured
# projects through their own loopback mitmproxy listener (without new DNS
# lookups), capture.conf/egress.sh/Caddy routes are generated consistently, the
# addon behaves (tests/capture_addon_test.py), and the entrypoint trusts the
# capture CA and follows the egress proxy's move.
source "$(dirname "$0")/../lib.sh"
source_nixenv

ENGINE=docker
ensure_internal_net() { :; }
container_running()   { return 1; }
net_subnet() {
  case "$1" in
    *_alpha_egress) echo "172.30.9.0/24";;
    *_beta_egress)  echo "172.30.10.0/24";;
    *_gamma_egress) echo "172.30.11.0/24";;
    "$EGRESS_NET")  echo "172.26.0.0/16";;
    *)              echo "172.18.0.0/16";;
  esac
}

rm -rf "$PROJECTS_DIR" "$PROXY_DIR"
for p in alpha beta gamma open; do mkdir -p "$PROJECTS_DIR/$p"; done
echo example.com > "$PROJECTS_DIR/alpha/allowed_hosts"
echo example.org > "$PROJECTS_DIR/beta/allowed_hosts"
echo example.net > "$PROJECTS_DIR/gamma/allowed_hosts"
: > "$PROJECTS_DIR/alpha/capture"                  # empty = both directions
echo egress > "$PROJECTS_DIR/beta/capture"         # egress only
touch "$PROJECTS_DIR/open/unrestricted" "$PROJECTS_DIR/open/capture"   # ignored: not restricted

# --- project_captures / capture_directions ------------------------------------
project_captures alpha egress  || fail "empty capture file = egress"
project_captures alpha ingress || fail "empty capture file = ingress"
project_captures beta egress   || fail "beta captures egress"
project_captures beta ingress  && fail "beta does not capture ingress"
project_captures gamma egress  && fail "no capture file = nothing"
assert_eq "$(capture_directions alpha)" "egress ingress"
assert_eq "$(capture_directions beta)" "egress"

# --- generated configs --------------------------------------------------------
write_egress_configs >/dev/null
edir="$PROXY_DIR/egress"
conf="$(cat "$edir/squid.conf")"
capconf="$(cat "$edir/capture.conf")"
assert_eq "$(printf '%s' "$CAPTURE_PROJECTS" | tr -s ' ' | sed 's/^ //')" "alpha beta" "captured = restricted projects with a capture file"
assert_eq "$CAPTURE_CHANGED" 1 "first write reports a change"
assert_contains "$capconf" "egress alpha $((CAPTURE_EGRESS_BASE + 1))"
assert_contains "$capconf" "ingress alpha $((CAPTURE_INGRESS_BASE + 1)) nxt-alpha" "ingress names the project's container"
assert_contains "$capconf" "egress beta $((CAPTURE_EGRESS_BASE + 2))"
assert_not_contains "$capconf" "ingress beta" "egress-only project has no ingress listener"
assert_not_contains "$capconf" "open" "unrestricted project never captured"
assert_contains "$capconf" "link 172.26.0.0/16" "link subnet = the egress network"
assert_contains "$CAPTURE_INGRESS" "alpha $((CAPTURE_INGRESS_BASE + 1))"

assert_contains "$conf" "cache_peer 127.0.0.1 parent $((CAPTURE_EGRESS_BASE + 1)) 0 no-query no-digest no-netdb-exchange name=cap_alpha"
assert_contains "$conf" "cache_peer_access cap_alpha allow p_alpha !nocapture_ports"
assert_contains "$conf" "cache_peer_access cap_alpha deny all"
assert_contains "$conf" "never_direct allow p_alpha !nocapture_ports" "fail closed: never bypass mitmproxy"
assert_contains "$conf" "acl nocapture_ports port 22 9418" "ssh/git:// stay direct"
assert_not_contains "$conf" "cap_gamma" "uncaptured project goes direct"
# Routing must not add a DNS lookup: only src (p_*) and port ACLs there.
printf '%s\n' "$conf" | grep -E '^(cache_peer_access|never_direct)' \
  | grep -vE '^(cache_peer_access cap_[a-z_]+ (allow p_[a-z_]+ !nocapture_ports|deny all)|never_direct allow p_[a-z_]+ !nocapture_ports)$' \
  && fail "capture routing uses an ACL that may resolve names"
# …and http_access still decides first: a captured project's denied name is
# refused, unresolved, exactly as before.
sim() { python3 "$TESTS_DIR/squid_acl_sim.py" "$edir/squid.conf" "$@"; }
assert_eq "$(sim 172.30.9.5 CONNECT secret.attacker.example 443)" "deny dns=no" "captured: denied name not resolved"
assert_eq "$(sim 172.30.9.5 CONNECT example.com 443)" "allow dns=yes" "captured: allowed name works"

# Unchanged inputs → capture.conf untouched → mitmproxy is not restarted.
write_egress_configs >/dev/null
assert_eq "$CAPTURE_CHANGED" 0 "no change → no mitmproxy restart"
rm -f "$PROJECTS_DIR/beta/capture"
write_egress_configs >/dev/null
assert_eq "$CAPTURE_CHANGED" 1 "a toggled project changes the listeners"
assert_not_contains "$(cat "$edir/capture.conf")" "beta"
echo egress > "$PROJECTS_DIR/beta/capture"
write_egress_configs >/dev/null

# UI token: generated once, owner-only, stable.
tok1="$(cat "$EGRESS_DATA_DIR/mitmweb.token")"
[ "${#tok1}" -ge 32 ] || fail "UI token too short: $tok1"
write_egress_configs >/dev/null
assert_eq "$(cat "$EGRESS_DATA_DIR/mitmweb.token")" "$tok1" "token is stable across regenerations"
case "$(ls -ld "$EGRESS_DATA_DIR" | cut -c1-10)" in drwx------) ;; *) fail "egress data dir must be owner-only";; esac

# --- egress.sh: listeners, binding, supervision ------------------------------
eg="$(cat "$edir/egress.sh")"
sh -n "$edir/egress.sh" || fail "egress.sh parses"
assert_contains "$eg" '--mode "regular@127.0.0.1:$_port"' "egress listeners: loopback only (squid is the only client)"
assert_contains "$eg" '--mode "regular@$_bind:$_port"' "ingress listeners: the link address only"
assert_contains "$(cat "$edir/capture.conf")" 'link 172.26.0.0/16' "link subnet in capture.conf"
# The subnet is read from capture.conf at each mitmproxy start, never baked into
# egress.sh: that shell outlives 'capture on', and a stale empty value bound the
# UI to 127.0.0.1 (Caddy 502 on <project>-mitm).
assert_not_contains "$(code_only < "$edir/egress.sh")" 'LINK_SUBNET' "link subnet not frozen into egress.sh"
assert_contains "$eg" "s/^link " "loop reads the link subnet from capture.conf"
assert_contains "$eg" 'if [ "$#" -gt 0 ]' "no listener → don't start (mitmproxy would default to 0.0.0.0:8080)"
assert_contains "$eg" 'web_host="${_bind:-127.0.0.1}"' "UI never on a project-facing address"
assert_contains "$eg" 'web_password="$(cat /data/mitmweb.token' "UI password"
assert_contains "$eg" "/data/run/mitm.pid" "restartable in place"
assert_not_contains "$(code_only < "$edir/egress.sh")" "0.0.0.0" "nothing binds every interface"

# pick_addr picks by SUBNET, not position (interface order isn't stable).
pa="$NIXTEST_HOME/pick.sh"
{ pick_addr_fn; echo 'hostname() { echo "10.89.1.5 172.26.0.3 172.30.9.2 "; }'; echo 'pick_addr "$1"'; } > "$pa"
assert_eq "$(sh "$pa" 172.26.0.0/16)" "172.26.0.3"
assert_eq "$(sh "$pa" 10.89.1.0/24)" "10.89.1.5"
assert_eq "$(sh "$pa" 172.30.9.0/26)" "172.30.9.2"
assert_eq "$(sh "$pa" 192.168.0.0/16)" "" "no address in the subnet → empty"
assert_eq "$(sh "$pa" '')" "" "no subnet → empty"
# The caddy container's relays use it too (fallback: first address).
assert_contains "$(cat "$edir/start.sh")" 'RELAY_BIND="$(pick_addr "172.18.0.0/16")"'

# --- the addon -----------------------------------------------------------------
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$edir/nixenv_capture.py" \
  || fail "addon is not valid python"
aw="$NIXTEST_HOME/addon"; rm -rf "$aw"; mkdir -p "$aw"
out="$(python3 "$TESTS_DIR/capture_addon_test.py" "$edir/nixenv_capture.py" "$aw" 2>&1)" \
  || fail "addon behaviour: $out"

# --- Caddy: ingress capture routes ---------------------------------------------
EGRESS_SUBNETS="alpha 172.30.9.0/24
beta 172.30.10.0/24"
write_caddyfile 0
cf="$(cat "$PROXY_DIR/Caddyfile")"
assert_contains "$cf" '@cap_alpha header_regexp cap_alpha Host ^alpha-([0-9]+)\.nixenv\.localhost(:[0-9]+)?$'
assert_contains "$cf" "reverse_proxy @cap_alpha nxt-alpha:{re.cap_alpha.1}"
assert_contains "$cf" "forward_proxy_url http://$EGRESS_LINK:$((CAPTURE_INGRESS_BASE + 1))"
assert_contains "$cf" "header_up X-Nixenv-Upstream nxt-alpha:{re.cap_alpha.1}"
assert_not_contains "$cf" "@cap_beta" "egress-only project: ingress untouched"
# The mitmweb UI: <p>-mitm.<domain> for EVERY captured project, through Caddy.
assert_contains "$cf" "@capui_alpha host alpha-mitm.$PROXY_DOMAIN"
assert_contains "$cf" "@capui_beta host beta-mitm.$PROXY_DOMAIN" "egress-only project still gets the UI"
assert_contains "$cf" "reverse_proxy @capui_alpha $EGRESS_LINK:$CAPTURE_WEB_IN_PORT"
assert_not_contains "$cf" "@capui_gamma" "uncaptured project: no UI host"
# A restricted project may never reach the UI: its guard only admits <name>-<digits>.
case "alpha-mitm.$PROXY_DOMAIN" in *-[0-9]*.*) fail "UI host would pass the isolation guard";; esac
assert_eq "$(PROXY_HTTPS_PORT=443 capture_ui_url alpha)" "https://alpha-mitm.$PROXY_DOMAIN"
assert_eq "$(PROXY_HTTPS_PORT=8443 capture_ui_url alpha)" "https://alpha-mitm.$PROXY_DOMAIN:8443"
# Order inside route{}: isolation denies → capture route → generic route.
ln() { printf '%s\n' "$cf" | grep -n -- "$1" | head -1 | cut -d: -f1; }
[ "$(ln 'respond @xproj_alpha')" -lt "$(ln 'reverse_proxy @cap_alpha')" ] || fail "isolation must run before ingress capture"
[ "$(ln 'reverse_proxy @cap_alpha')" -lt "$(ln 'reverse_proxy @route')" ] || fail "capture route must precede the generic one"
[ "$(ln 'respond @xproj_alpha')" -lt "$(ln 'reverse_proxy @capui_alpha')" ] || fail "isolation must run before the UI route"
[ "$(ln 'reverse_proxy @capui_alpha')" -lt "$(ln 'no route for')" ] || fail "UI route must precede the 502"
if have caddy; then
  cout="$(caddy adapt --config "$PROXY_DIR/Caddyfile" --adapter caddyfile 2>&1 >/dev/null)" \
    || fail "caddy rejects the generated Caddyfile: $cout"
else
  note "caddy not on PATH — Caddyfile not validated by caddy"
fi

# --- wiring in nixenv.sh ------------------------------------------------------------
body="$(cat "$NIXENV_SH")"
run_fn="$(printf '%s' "$body" | sed -n '/^cmd_run()/,/^}/p' | code_only)"
assert_contains "$run_fn" 'NIXENV_EGRESS_PROXY="http://$EGRESS_NAME:$EGRESS_PORT"' "projects use the egress container"
assert_contains "$run_fn" '/etc/nixenv-capture-ca.crt:ro' "capture CA mounted"
assert_contains "$run_fn" 'capture_ca_trusted "$name"' "CA mount follows the kept trust, not just capture on"
# Kept trust (dev-only): egress capture on, or the marker 'capture on' writes.
capture_ca_trusted alpha || fail "egress capture on → trusted"
capture_ca_trusted gamma && fail "never captured → not trusted"
touch "$PROJECTS_DIR/gamma/capture-trust"
capture_ca_trusted gamma || fail "capture-trust marker → still trusted after off"
rm -f "$PROJECTS_DIR/gamma/capture-trust"
cap_fn="$(printf '%s' "$body" | sed -n '/^cmd_capture()/,/^}/p' | code_only)"
assert_contains "$cap_fn" ': > "$pdir/capture-trust"' "'capture on' records the trust"
assert_contains "$cap_fn" 'untrust)' "'capture untrust' revokes it"
nr_fn="$(printf '%s' "$body" | sed -n '/^container_needs_recreate()/,/^}/p' | code_only)"
assert_contains "$nr_fn" 'capture_ca_trusted "$name"' "stale-container warning follows the kept trust"
assert_not_contains "$(printf '%s' "$body" | sed -n '/^EXPORT_META_FILES=/p')" "capture-trust" "trust is not exported"
px_fn="$(printf '%s' "$body" | sed -n '/^cmd_proxy()/,/^}/p' | code_only)"
up_ln="$(printf '%s\n' "$px_fn" | grep -n 'egress_up' | head -1 | cut -d: -f1)"
rm_ln="$(printf '%s\n' "$px_fn" | grep -n 'rm -f "$PROXY_NAME"' | head -1 | cut -d: -f1)"
[ "$up_ln" -lt "$rm_ln" ] || fail "egress must be up before caddy is recreated"
eg_fn="$(printf '%s' "$body" | sed -n '/^egress_run()/,/^}/p' | code_only)"
assert_contains "$eg_fn" '--network-alias "$EGRESS_LINK"'
assert_contains "$eg_fn" 'container_hardening_args' "egress container hardened"
up_fn="$(printf '%s' "$body" | sed -n '/^egress_up()/,/^}/p' | code_only)"
assert_not_contains "$up_fn$eg_fn" '-p "127.0.0.1:' "egress container publishes nothing (UI goes through Caddy)"
assert_contains "$eg_fn" '--label "$EGRESS_SUM_LABEL=$(egress_script_sum)"' "egress container records its script"
# A running egress container is reloaded only while it runs the CURRENT egress.sh:
# the script is read once at start, so an older one (no/other label) must be
# recreated, or e.g. the link-subnet fix never reaches it (502 on capture).
eu_log="$NIXTEST_HOME/egress-up.log"
(
  EGRESS_PROJECTS=" alpha"
  ensure_egress_net() { :; }
  egress_connect_nets() { :; }
  egress_reload() { echo reload >> "$eu_log"; }
  egress_run() { echo run >> "$eu_log"; }
  container_running() { [ "$1" = "$EGRESS_NAME" ]; }
  docker() {
    case "$1" in
      port) ;;
      inspect) printf '%s\n' "${FAKE_LABEL:-}";;
      rm) ;;
    esac
  }
  ENGINE=docker
  : > "$eu_log"; FAKE_LABEL="";                    egress_up >/dev/null 2>&1
  assert_eq "$(cat "$eu_log")" "run" "unlabelled (pre-fix) egress container is recreated"
  : > "$eu_log"; FAKE_LABEL="$(egress_script_sum)"; egress_up >/dev/null 2>&1
  assert_eq "$(cat "$eu_log")" "reload" "current egress.sh → reload in place"
  : > "$eu_log"; FAKE_LABEL="1-2";                 egress_up >/dev/null 2>&1
  assert_eq "$(cat "$eu_log")" "run" "changed egress.sh → recreated"
) || fail "egress_up staleness check"
cap_fn="$(printf '%s' "$body" | sed -n '/^cmd_capture()/,/^}/p' | code_only)"
assert_contains "$cap_fn" 'capture_ui_url "$name"' "capture web prints the Caddy URL"
assert_not_contains "$(printf '%s' "$body" | code_only)" 'CAPTURE_WEB_PORT' "no host-published UI port left"
allow_fn="$(printf '%s' "$body" | sed -n '/^cmd_allow()/,/^}/p' | code_only)"
assert_contains "$allow_fn" 'exec "$EGRESS_NAME" "$PROFILE/bin/squid"' "allow reloads squid where it runs"
assert_not_contains "$(printf '%s' "$body" | code_only)" 'exec "$PROXY_NAME" "$PROFILE/bin/squid"' "no squid left in the caddy container"
# Delete removes recorded traffic (it can hold the project's tokens).
del_fn="$(printf '%s' "$body" | sed -n '/^cmd_delete()/,/^}/p' | code_only)"
assert_contains "$del_fn" 'captures/$name.flows'
# Base flake ships mitmproxy.
materialize_context
assert_contains "$(code_only < "$CONTEXT_DIR/flake.nix")" "mitmproxy" "base flake has mitmproxy"

# --- reserved name, unrestricted refusal -------------------------------------
valid_project_name egress 2>/dev/null && fail "'egress' must be reserved"
out="$( (cmd_capture open on) 2>&1 || true)"
assert_contains "$out" "unrestricted" "capture refuses an unrestricted project"
out="$( (cmd_capture alpha on sideways) 2>&1 || true)"
assert_contains "$out" "usage" "bad direction rejected"

# --- entrypoint: CA trust + egress address migration ---------------------------
ep="$(cat "$CONTEXT_DIR/entrypoint.sh")"
assert_contains "$ep" "/etc/nixenv-capture-ca.crt" "entrypoint merges the capture CA"
assert_contains "$ep" '.nixenv-extra-ca.crt' "Node gets ONE file with every extra CA"
# Run the migration block for real against a home written for the OLD address.
mig="$NIXTEST_HOME/mig"; rm -rf "$mig"; mkdir -p "$mig/.ssh"
cat > "$mig/.npmrc" <<'EOF'
registry=https://registry.npmjs.org/
# nixenv-egress
proxy=http://nixenv-proxy:3128
https-proxy=http://nixenv-proxy:3128
noproxy=localhost
EOF
printf '# nixenv-egress\nproxy "http://nixenv-proxy:3128"\nhttps-proxy "http://nixenv-proxy:3128"\n' > "$mig/.yarnrc"
cat > "$mig/.ssh/config" <<'EOF'
Host mine
    User me

# nixenv-egress (auto-added on restricted projects; delete this block to opt out)
Host * !localhost !127.0.0.1 !nixenv-proxy !*.local !*.internal !*.localhost !nixenv-*
    ProxyCommand /p/bin/socat - PROXY:nixenv-proxy:%h:%p,proxyport=3128
EOF
block="$(printf '%s\n' "$ep" | sed -n '/^  # The blocks below are written ONCE/,/> "\$HOME_DIR\/.nixenv-egress-proxy"$/p')"
[ -n "$block" ] || fail "migration block not found in the entrypoint"
run_mig() {
  HOME_DIR="$mig" NIXENV_EGRESS_PROXY="$1" _ephost="${1#http://}" _epport=3128 \
    sh -c "_ephost=\"\${_ephost%%:*}\"; $block"
}
run_mig "http://nixenv-egress:3128" >/dev/null
assert_contains "$(cat "$mig/.npmrc")" "https-proxy=http://nixenv-egress:3128"
assert_not_contains "$(cat "$mig/.npmrc")" "nixenv-proxy" "npmrc fully retargeted"
assert_contains "$(cat "$mig/.npmrc")" "registry=https://registry.npmjs.org/" "user lines kept"
assert_not_contains "$(cat "$mig/.yarnrc")" "nixenv-proxy" "yarnrc retargeted"
sshc="$(cat "$mig/.ssh/config")"
assert_contains "$sshc" "PROXY:nixenv-egress:%h:%p,proxyport=3128"
assert_contains "$sshc" "!nixenv-egress !*.local" "exclusion follows the proxy"
assert_contains "$sshc" "Host mine" "user hosts kept"
assert_eq "$(cat "$mig/.nixenv-egress-proxy")" "http://nixenv-egress:3128" "address recorded"
# Idempotent: same address again changes nothing.
cp "$mig/.npmrc" "$mig/npmrc.before"
assert_eq "$(run_mig "http://nixenv-egress:3128")" "" "no message when unchanged"
cmp -s "$mig/.npmrc" "$mig/npmrc.before" || fail "unchanged address must not rewrite files"
true
