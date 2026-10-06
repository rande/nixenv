#!/usr/bin/env bash
# 'nixenv ps' + the dashboard at https://<domain>/ (NET-05): the probe parser
# (hostile process names included), the egress-log subnet match, the JSON and
# table, the Caddy site block, the page's no-markup rule, and the wiring into
# run/stop/proxy.
source "$(dirname "$0")/../lib.sh"
source_nixenv

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- probe: only base-Debian tools (RUN-13) ------------------------------------
for tool in git zsh socat ss netstat lsof '$PROFILE'; do
  assert_not_contains "$DASHBOARD_PROBE" "$tool" "probe must not need '$tool'"
done
sh -n -c "$DASHBOARD_PROBE" || fail "probe is valid POSIX sh"

# --- parser --------------------------------------------------------------------
cat > "$T/alpha.probe" <<'EOF'
##nixenv tcp
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1001 1 0 100 0 0 10 0
   1: 0100007F:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1002 1 0 100 0 0 10 0
   2: 00000000:08AE 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1003 1 0 100 0 0 10 0
   3: 0100007F:01BB 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1004 1 0 100 0 0 10 0
   4: 0500120A:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1005 1 0 100 0 0 10 0
   5: 00000000:1F91 0100007F:1234 01 00000000:00000000 00:00000000 00000000  1000        0 1009 1 0 100 0 0 10 0
   7: 0B00007F:986B 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1011 1 0 100 0 0 10 0
   6: zzzzzzzz:1F92 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1010 1 0 100 0 0 10 0
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1006 1 0 100 0 0 10 0
   1: 0000000000000000FFFF00000100007F:1F40 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1007 1 0 100 0 0 10 0
   2: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1008 1 0 100 0 0 10 0
##nixenv fd
/proc/1/fd:
total 0
lrwx------ 1 app app 64 Oct  6 10:00 3 -> socket:[1001]
lrwx------ 1 app app 64 Oct  6 10:00 4 -> socket:[1008]

/proc/20/fd:
lrwx------ 1 app app 64 Oct  6 10:00 5 -> socket:[1002]
lr-x------ 1 app app 64 Oct  6 10:00 6 -> /tmp/##nixenv sv
/proc/30/fd:
lrwx------ 1 app app 64 Oct  6 10:00 7 -> socket:[1006]
/proc/40/fd:
lrwx------ 1 app app 64 Oct  6 10:00 3 -> socket:[1005]
##nixenv comm
==> /proc/1/comm <==
nginx

==> /proc/20/comm <==
##nixenv sv
==> /proc/30/comm <==
<img src=x onerror=alert(1)>
==> /proc/40/comm <==
node
##nixenv sv
sshd run
nginx run
worker down
proxy-relay-443 run
"><b> x
EOF
got="$(dashboard_parse_probe < "$T/alpha.probe")"
want='L 8080 any nginx
L 5432 loopback __nixenv_sv
L 9000 10.18.0.5 node
L 3000 any _img_src_x_onerror_alert
L 8000 loopback -
S sshd run
S nginx run
S worker down
S proxy-relay-443 run
S ___b_ x'
# Services print as they're read, ports at the end: compare as sets.
assert_eq "$(printf '%s\n' "$got" | sort)" "$(printf '%s\n' "$want" | sort)" "parsed probe"
assert_not_contains "$got" " 2222 " "the in-container sshd is nixenv's own"
assert_not_contains "$got" "L 443 " "the loopback proxy relay is nixenv's own"
assert_not_contains "$got" "8081" "only LISTEN sockets"
assert_not_contains "$got" "8082" "non-hex addresses dropped"
assert_not_contains "$got" "39019" "root-owned sockets (Docker's DNS) are the engine's"
printf '%s\n' "$got" | grep -q '[<>"]' && fail "nothing markup-like survives the parser"
# A process named like a section marker must not switch sections.
printf '%s\n' "$got" | grep -q '^S ==>' && fail "comm '##nixenv sv' switched the parser to services"
# Caps: a container can't flood the page.
{ echo "##nixenv sv"; i=0; while [ $i -lt 100 ]; do echo "s$i run"; i=$((i+1)); done; } > "$T/flood"
assert_eq "$(dashboard_parse_probe < "$T/flood" | wc -l | tr -d ' ')" 64 "services capped at 64"

# --- egress hits: the project's subnet exactly, not a text prefix ----------------
mkdir -p "$T/egress-data"
cat > "$T/egress-data/egress.log" <<'EOF'
1.0 1 172.30.9.5 TCP_TUNNEL/200 100 CONNECT github.com:443 - HIER_DIRECT/1.2.3.4 -
1.0 1 172.30.9.5 TCP_TUNNEL/200 100 CONNECT github.com:443 - HIER_DIRECT/1.2.3.4 -
1.0 1 172.30.9.7 TCP_DENIED/403 0 CONNECT evil.example:443 - HIER_NONE/- -
1.0 1 172.30.9.7 TCP_DENIED/403 0 GET http://x"><script>.example/path - HIER_NONE/- -
1.0 1 172.30.90.7 TCP_DENIED/403 0 CONNECT other-project.example:443 - HIER_NONE/- -
1.0 1 172.30.1.7 TCP_DENIED/403 0 CONNECT other-project.example:443 - HIER_NONE/- -
EOF
hits="$(EGRESS_DATA_DIR="$T/egress-data" dashboard_egress_hits 172.30.9.0/24)"
assert_contains "$hits" "A github.com 2" "allowed hosts counted"
assert_contains "$hits" "D evil.example 1" "denied hosts counted"
assert_contains "$hits" "D xscript.example 1" "odd characters stripped from a requested host"
assert_not_contains "$hits" "other-project" "172.30.90.x / 172.30.1.x are not in 172.30.9.0/24"
assert_eq "$(EGRESS_DATA_DIR="$T/egress-data" dashboard_egress_hits '')" "" "no subnet → nothing"

# --- JSON helpers ----------------------------------------------------------------
assert_eq "$(json_s 'a"b\c')" '"a\"b\\c"' "json_s escapes quotes and backslashes"
assert_eq "$(json_s "$(printf 'a\tb')")" '"ab"' "json_s drops control characters"
assert_eq "$(printf 'x\n\ny\n' | json_list)" '["x","y"]' "json_list skips blanks"

# --- full scan with a fake engine --------------------------------------------------
cat > "$T/engine" <<'EOF'
#!/bin/sh
case "$1" in
  ps) if [ "${2:-}" = -a ]; then printf 'nxt-alpha\nnxt-open\nnxt-gone\nnxt__proxy\n'
      else printf 'nxt-alpha\nnxt-open\nnxt__proxy\n'; fi;;
  inspect) case "$*" in
      *Mounts*)    echo "/data /etc/caddy/Caddyfile /www ";;
      *StartedAt*) echo "2026-10-06T10:00:00.123456Z";;
      *Env*)       echo "NIXENV_EGRESS_PROXY=http://nxt__egress:3128";;
    esac;;
  exec) cat "$FAKE_PROBES/$2.probe" 2>/dev/null;;
  network) echo "172.30.9.0/24";;
esac
EOF
chmod +x "$T/engine"
mkdir -p "$T/probes"; cp "$T/alpha.probe" "$T/probes/nxt-alpha.probe"
export FAKE_PROBES="$T/probes"
ENGINE="$T/engine"
EGRESS_DATA_DIR="$T/egress-data"
rm -rf "$PROJECTS_DIR" "$PROXY_DIR"
DASHBOARD_DIR="$PROXY_DIR/www"
mkdir -p "$PROJECTS_DIR/alpha" "$PROJECTS_DIR/open" "$PROJECTS_DIR/gone" "$PROJECTS_DIR/bad name"
echo 2345 > "$PROJECTS_DIR/alpha/port"
printf 'github.com\n# comment\n.npmjs.org\n' > "$PROJECTS_DIR/alpha/allowed_hosts"
echo github.com > "$PROJECTS_DIR/alpha/ssh_hosts"
echo prod.internal.example > "$PROJECTS_DIR/alpha/deploy_hosts"
echo open > "$PROJECTS_DIR/alpha/accept-from"
echo 8080 > "$PROJECTS_DIR/alpha/ports"
touch "$PROJECTS_DIR/open/unrestricted"
cat > "$PROJECTS_DIR/alpha/extra-parameters" <<'EOF'
# limits
--memory=4g
-e API_TOKEN=ghp_secret1 --env DB_PASS=secret2
--env=OTHER=secret3 -eX=secret4 -e PLAIN
--device /dev/fuse
EOF

echo "deadbeefmitmwebtoken" > "$EGRESS_DATA_DIR/mitmweb.token"
: > "$PROJECTS_DIR/alpha/capture"
write_dashboard
for f in index.html style.css app.js status.json; do assert_file "$DASHBOARD_DIR/$f"; done
[ -z "$(ls -A "$DASHBOARD_DIR" | grep '^\.')" ] || fail "no temp files left behind"
j="$(cat "$DASHBOARD_DIR/status.json")"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$DASHBOARD_DIR/status.json" <<'EOF' || fail "status.json content"
import json, sys
d = json.load(open(sys.argv[1]))
ps = {p["name"]: p for p in d["projects"]}
assert set(ps) == {"alpha", "open", "gone"}, ps.keys()          # 'bad name' skipped
a = ps["alpha"]
assert a["state"] == "running" and a["restricted"] is True
assert a["ssh_port"] == "2345" and a["started"] == "2026-10-06T10:00:00"
assert a["allowed_hosts"] == ["github.com", ".npmjs.org"], a["allowed_hosts"]
assert a["ssh_hosts"] == ["github.com"] and a["accept_from"] == ["open"]
assert a["deploy_hosts"] == 1                                     # a count, never the hosts
assert a["extra_parameters"] == ["--memory=4g", "-e", "API_TOKEN=…", "--env", "DB_PASS=…",
    "--env=OTHER=…", "-eX=…", "-e", "PLAIN", "--device", "/dev/fuse"], a["extra_parameters"]
assert "egress_allowed" not in a and "app_mount" not in a          # no longer shown
assert ps["open"]["extra_parameters"] == []
l = {x["port"]: x for x in a["listening"]}
assert l[8080]["url"] == "https://alpha-8080.nixenv.localhost:18443/", l[8080]
assert l[5432]["bind"] == "loopback" and l[5432]["url"] == ""
assert {"name": "worker", "state": "down"} in a["services"]
assert {"host": "evil.example", "count": 1} in a["egress_denied"]
assert any("egress proxy not running" in w for w in a["warnings"]), a["warnings"]
assert any("worker" in w and "nixenv logs alpha" in w for w in a["warnings"]), a["warnings"]   # plain nixenv on the page
assert ps["open"]["restricted"] is False and ps["open"]["ssh_hosts"] is None
assert ps["open"]["listening"] == []                              # no probe file → nothing
assert ps["gone"]["state"] == "stopped"
assert d["proxy"] == {"running": True, "serves_dashboard": True, "tls": "internal"}
assert d["egress"]["running"] is False and d["prefix"] == "nxt"
EOF
else
  note "python3 missing — JSON checked textually only"
fi
assert_not_contains "$j" "prod.internal.example" "deploy hosts never reach the page"
assert_not_contains "$(cat "$DASHBOARD_DIR"/*)" "deadbeefmitmwebtoken" "the mitmweb token (UI password) never reaches the page"
assert_contains "$j" '"capture":"egress ingress"' "capture directions are published"
for secret in ghp_secret1 secret2 secret3 secret4; do
  assert_not_contains "$j" "$secret" "environment values in extra-parameters are redacted"
done
ln -s "$PROJECTS_DIR/alpha/extra-parameters" "$PROJECTS_DIR/open/extra-parameters"
assert_eq "$(dashboard_extra_params open)" "" "a symlinked extra-parameters is not followed"
rm -f "$PROJECTS_DIR/open/extra-parameters"
assert_contains "$DASH_TABLE" "alpha" "table lists projects"
assert_contains "$DASH_TABLE" "8080  nginx  https://alpha-8080.nixenv.localhost:18443/" "table shows the URL"
assert_contains "$DASH_TABLE" "5432  __nixenv_sv  (127.0.0.1 only" "table flags loopback-only ports"
assert_contains "$DASH_TABLE" "evil.example×1" "table shows denied hosts"
assert_contains "$DASH_TABLE" "check: $0 logs alpha" "the terminal names the script that ran"
assert_not_contains "$DASH_TABLE$j" "@NIXENV@" "placeholder always substituted"

# An older proxy (no /www mount) answers the bare domain with an EMPTY 200:
# detected, so ps and run can say "proxy up" instead of leaving a blank page.
proxy_serves_dashboard || fail "the fake proxy mounts /www"
( ENGINE="$T/engine-old"; printf '#!/bin/sh\necho "/data /etc/caddy/Caddyfile "\n' > "$ENGINE"; chmod +x "$ENGINE"
  proxy_serves_dashboard && exit 1; exit 0 ) || fail "a proxy without /www is detected"

# Refresh is best effort: a broken engine must not fail run/stop.
( ENGINE=false; dashboard_refresh ) || fail "dashboard_refresh never fails"
( DASHBOARD_REFRESH=0; DASHBOARD_DIR="$T/none"; dashboard_refresh; [ ! -e "$T/none" ] ) \
  || fail "DASHBOARD_REFRESH=0 skips the refresh"

# --- delayed refresh after 'run': services take a while to listen -----------------
wait_file() { local i=0; while [ ! -f "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done; [ -f "$1" ]; }
tokf="$PROXY_DIR/.dashboard-refresh"
rm -f "$DASHBOARD_DIR/status.json"
DASHBOARD_DELAYS="1"; dashboard_refresh_later
wait_file "$DASHBOARD_DIR/status.json" || fail "the delayed refresher rescans after its delay"
i=0; while [ -f "$tokf" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
assert_no_file "$tokf" "the refresher cleans up its token when done"
# A newer one (another 'run') supersedes it: the old one exits without writing.
rm -f "$DASHBOARD_DIR/status.json"
DASHBOARD_DELAYS="1"; dashboard_refresh_later
echo "someone-newer" > "$tokf"
sleep 2
assert_no_file "$DASHBOARD_DIR/status.json" "a superseded refresher does nothing"
assert_eq "$(cat "$tokf")" "someone-newer" "and leaves the newer token alone"
rm -f "$tokf"
DASHBOARD_DELAYS=""; dashboard_refresh_later
assert_no_file "$tokf" "NIXENV_DASHBOARD_DELAYS= (empty) disables it"
( DASHBOARD_DELAYS="1"; DASHBOARD_REFRESH=0; dashboard_refresh_later; [ ! -f "$tokf" ] ) \
  || fail "DASHBOARD_REFRESH=0 disables it too"
assert_eq "$(NIXENV_DASHBOARD_DELAYS= bash -c "source '$NIXENV_SH'; printf %s \"\$DASHBOARD_DELAYS\"")" "" "an empty env value is kept, not defaulted"
assert_eq "$(bash -c "unset NIXENV_DASHBOARD_DELAYS; source '$NIXENV_SH'; printf %s \"\$DASHBOARD_DELAYS\"")" "10 30 90" "default delays"

# --- the page: data as text only, no inline code -------------------------------------
js="$(dashboard_js)"; html="$(dashboard_html)"
for bad in innerHTML outerHTML insertAdjacentHTML document.write 'eval(' 'new Function'; do
  assert_not_contains "$js" "$bad" "app.js must not use $bad"
done
assert_contains "$js" "textContent" "renders with textContent"
printf '%s\n' "$html" | grep -q '<script>' && fail "no inline script in index.html"
printf '%s\n' "$html" | grep -qi ' style=' && fail "no inline style attributes (CSP style-src 'self')"
printf '%s\n' "$html" | grep -qi ' on[a-z]*=' && fail "no inline event handlers"
assert_contains "$html" '<script src="app.js" defer></script>'
assert_contains "$(dashboard_css)" 'data-sheet="blueprint"' "same paper/blueprint sheets as docs/index.html"
assert_not_contains "$js" '"cmd"' "no command box on the cards (Help has them)"
assert_contains "$js" '"-mitm." + data.domain' "a captured project links its mitmweb UI"
assert_not_contains "$js" 'token=' "the link never carries the token"
assert_contains "$js" 'c.id = "project-" + p.name' "each card is anchored as #project-<name>"
assert_contains "$js" '/^#project-([a-zA-Z0-9_-]+)$/' "the hash is validated before lookup"
assert_contains "$js" '"hashchange"' "a new hash re-focuses"
assert_eq "$(dashboard_project_url shop)" "$(dashboard_page_url)#project-shop" "project deep link"

# 02 · Commands documents every command main dispatches (so the page can't drift).
help="$(printf '%s\n' "$html" | sed -n '/<section id="commands">/,/<\/section>/p')"
[ -n "$help" ] || fail "the page has a Commands section"
assert_contains "$html" '<a href="#commands">Commands</a>' "nav names Commands"
cmds="$(sed -n '/^main() {/,/^}/p' "$NIXENV_SH" | grep -oE '^    [a-z][a-z|-]*\)' | tr -d ' )' | cut -d'|' -f1 | sort -u)"
[ "$(printf '%s\n' "$cmds" | wc -l)" -gt 25 ] || fail "found the dispatch table ($cmds)"
for c in $cmds; do
  case "$c" in help|version) continue;; esac
  printf '%s\n' "$help" | grep -qE "<td>$c( |<)|· $c( |<)" || fail "Commands does not document '$c'"
done

# 03 · New project: how to adopt a repo, then a COLLAPSED model flake that
# follows the template rules (services as files, hook, 0.0.0.0, no runtime in base).
newp="$(printf '%s\n' "$html" | sed -n '/<section id="new-project">/,/<\/section>/p')"
[ -n "$newp" ] || fail "the page has a New project section"
for c in "nixenv init shop" "nixenv build shop" "nixenv allow shop" "nixenv start shop" ".nixenv/hooks.sh"; do
  assert_contains "$newp" "$c" "new-project steps mention $c"
done
assert_contains "$newp" "<b>Build on the host</b>" "explains builds run only from the host"
assert_contains "$newp" "mounted <b>read-only</b>" "…because the store is read-only in the container"
assert_contains "$newp" "<b>No root, ever</b>" "explains the non-root app user"
assert_contains "$newp" '<details class="model">' "the model flake is collapsed"
assert_not_contains "$newp" '<details class="model" open' "…by default"
# Between steps 2 and 3: inside the second <li>.
step2="$(printf '%s\n' "$newp" | awk '/<li>/{n++} n==2' | sed '/<li><b>Build it/,$d')"
assert_contains "$step2" '<details class="model">' "the model sits between steps 2 and 3"
# The embedded copy IS templates/flake.nix (CORE-01 keeps nixenv.sh self-contained).
[ "$(dashboard_model_flake | cksum)" = "$(cksum < "$REPO_DIR/templates/flake.nix")" ] \
  || fail "dashboard_model_flake differs from templates/flake.nix — update both"
raw="$(printf '%s\n' "$html" | sed -n '/<pre id="model-flake">/,/<\/pre>/p' | sed -e '1d' -e '$d')"
assert_not_contains "$raw" "<" "the model flake is HTML-escaped"
[ "$(printf '%s\n' "$raw" | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' | cksum)" = "$(cksum < "$REPO_DIR/templates/flake.nix")" ] \
  || fail "the page shows templates/flake.nix verbatim"
assert_contains "$newp" '<button class="copy" type="button" data-copy="model-flake" hidden>' "copy button, hidden without JS"
assert_contains "$js" 'navigator.clipboard.writeText(src.textContent)' "copy uses the clipboard API"
assert_contains "$js" 'selectNodeContents(src)' "…and falls back to selecting the text"

# --- Caddy serves it on the bare domain -------------------------------------------------
EGRESS_SUBNETS=""
write_caddyfile 0
cf="$(cat "$PROXY_DIR/Caddyfile")"
assert_contains "$cf" "
$PROXY_DOMAIN {" "site block for the bare domain"
assert_contains "$cf" "root * /www"
assert_contains "$cf" "file_server"
assert_not_contains "$cf" "browse" "no directory listing"
assert_contains "$cf" "Content-Security-Policy \"default-src 'none'; script-src 'self';" "strict CSP"
assert_contains "$cf" "Cache-Control no-store"
assert_not_contains "$cf" "@restricted" "no restricted project → no deny"
EGRESS_SUBNETS="alpha 10.89.1.0/24
beta 10.89.2.0/24
evil 1.2.3.4/32;}
"
write_caddyfile 0
cf="$(cat "$PROXY_DIR/Caddyfile")"
assert_contains "$cf" "@restricted remote_ip 10.89.1.0/24 10.89.2.0/24" "restricted projects can't read the dashboard"
assert_not_contains "$(printf '%s\n' "$cf" | grep '@restricted remote_ip')" ";}" "malformed subnet dropped"
dash="$(printf '%s\n' "$cf" | sed -n "/^$PROXY_DOMAIN {/,/^}/p")"
r_ln="$(printf '%s\n' "$dash" | grep -n 'respond @restricted' | cut -d: -f1)"
f_ln="$(printf '%s\n' "$dash" | grep -n 'file_server' | cut -d: -f1)"
[ -n "$r_ln" ] && [ "$r_ln" -lt "$f_ln" ] || fail "the deny sits before file_server"

# --- wiring --------------------------------------------------------------------------
body="$(code_only < "$NIXENV_SH")"
px_fn="$(printf '%s\n' "$body" | sed -n '/^cmd_proxy()/,/^}/p')"
assert_contains "$px_fn" '-v "$DASHBOARD_DIR":/www:ro' "the proxy mounts the dashboard read-only"
assert_contains "$px_fn" 'dashboard_refresh' "proxy up/reload refresh it"
run_fn="$(printf '%s\n' "$body" | sed -n '/^cmd_run()/,/^}/p')"
assert_contains "$run_fn" 'DASHBOARD_REFRESH=0; proxy_refresh_for_run' "run refreshes once, not inside the proxy refresh"
assert_contains "$run_fn" 'dashboard_refresh'
assert_contains "$run_fn" 'dashboard_refresh_later' "run re-checks once services had time to start"
assert_contains "$run_fn" '! proxy_serves_dashboard' "run says when the running proxy can't serve the page"
assert_contains "$js" 'p.started + "Z"' "started is parsed as UTC"
stop_fn="$(printf '%s\n' "$body" | sed -n '/^cmd_stop()/,/^}/p')"
[ "$(printf '%s\n' "$stop_fn" | grep -c 'dashboard_refresh')" = 2 ] || fail "stop (one and all) refreshes"
assert_contains "$(nx --help)" "ps [--json] [--watch [N]]" "help documents ps"
true
