# =============================================================================
# tests/lib-template.sh — shared checks every nixenv template must satisfy.
# Sourced by tests/unit/13x-template-*.sh AFTER tests/lib.sh + source_nixenv.
#   assert_template <name>
# =============================================================================

# Invariants that hold for every template, whatever stack it ships.
assert_template() {
  local t="$1" f body head
  f="$REPO_DIR/templates/$t.nix"
  assert_file "$f" "$t: templates/$t.nix exists"
  body="$(cat "$f")"
  head="$(head -25 "$f")"

  # --- metadata nixenv reads BEFORE building --------------------------------
  [ -n "$(template_meta "$f" description)" ] || fail "$t: missing '# nixenv:description'"
  [ -n "$(template_meta "$f" port)" ]        || fail "$t: missing '# nixenv:port'"
  [ -n "$(template_meta "$f" allow)" ]       || fail "$t: missing '# nixenv:allow'"
  case "$(template_meta "$f" port)" in
    ''|*[!0-9]*) fail "$t: port must be numeric";;
  esac
  # every declared egress host must survive the same validation as 'allow'
  local h
  for h in $(template_meta "$f" allow); do
    normalize_allowed_host "$h" >/dev/null || fail "$t: invalid allow entry '$h'"
  done
  # an app-path, if declared, must be absolute
  local ap; ap="$(template_meta "$f" app-path)"
  [ -z "$ap" ] || case "$ap" in /*) ;; *) fail "$t: app-path must be absolute";; esac

  # --- resolvable as a local template ---------------------------------------
  assert_eq "$(resolve_template "$f")" "$f" "$t: resolves as a local path"

  # --- header documents how to apply it -------------------------------------
  assert_contains "$head" "init" "$t: header shows the init command"
  assert_contains "$head" "--template=$t" "$t: header shows its own template name"

  # --- structure: a flake that ships a startup hook --------------------------
  assert_contains "$body" 'description ='          "$t: is a flake"
  assert_contains "$body" 'inputs.nixpkgs.url'     "$t: pins nixpkgs"
  assert_contains "$body" 'packages = forAllSystems' "$t: multi-system packages"
  assert_contains "$body" 'buildEnv'               "$t: aggregates into one env"
  assert_contains "$body" 'etc/nixenv-hooks.sh'    "$t: ships a startup hook"
  assert_contains "$body" 'nixenv_pre_ssh_start'   "$t: defines the hook function"
  assert_contains "$body" 'startupHook'            "$t: hook is in buildEnv paths"

  # --- runtime setup discipline ---------------------------------------------
  # A build can't write the app volume, so setup must be hook-side and guarded.
  assert_contains "$body" 'NIXENV_APP_MOUNT'       "$t: hook uses the app mount"
  printf '%s' "$body" | grep -q '\.nixenv/\.[a-z-]*installed\|\.nixenv/\.[a-z-]*scaffolded' \
    || fail "$t: no first-run marker (setup would repeat on every start)"

  # --- services are DECLARED as files, never written by shell heredocs -------
  # (heredocs nested inside a Nix '' string are fragile: indentation stripping
  # can break the terminator, silently producing an unparseable hook)
  printf '%s' "$body" | grep -q 'writeTextDir "sv/[a-z0-9-]*/run"' \
    || fail "$t: no sv/<name>/run declared via writeTextDir"
  printf '%s' "$body" | grep -q "cat > \"\$SVROOT" \
    && fail "$t: writes run scripts from the hook — declare them as files instead"
  # every declared service must exec a foreground process
  local n
  for n in $(printf '%s' "$body" | grep -o 'writeTextDir "sv/[a-z0-9-]*/run"' | sed 's|.*sv/\([a-z0-9-]*\)/run.*|\1|'); do
    printf '%s' "$body" | grep -q 'exec ' || fail "$t: service $n must exec a foreground process"
  done

  # --- scratch paths must be writable by the non-root app user --------------
  # "$APP.tmp" resolves to /app.tmp at the filesystem ROOT, which the app user
  # cannot create; scratch work belongs under $HOME or inside the app volume.
  # (comments stripped — they may legitimately mention the anti-pattern)
  printf '%s' "$body" | sed 's/[[:space:]]*#.*//' | grep -q '"\$APP"\?\.tmp' \
    && fail "$t: writes to \$APP.tmp (filesystem root, not writable by 'app')"

  # --- placeholders must be ones install_template substitutes ---------------
  local p
  for p in $(printf '%s' "$body" | grep -o '@@[A-Z_]*@@' | sort -u); do
    case "$p" in
      '@@PROJECT@@'|'@@APP_MOUNT@@'|'@@DOMAIN@@'|'@@PORT@@') ;;
      *) fail "$t: unknown placeholder $p";;
    esac
  done

  # --- a comment inside a Nix indented string must not contain a bare '' -----
  # '' both OPENS and CLOSES an indented string, so writing it in a comment that
  # sits inside one silently terminates the string there — the parse error then
  # points at the comment, not at the real problem. Two such comments cancel out
  # in a parity check, so match on position instead: top-level comments start at
  # column 0 and are fine; an INDENTED comment is inside a string. Escapes ('''
  # and ''${…}) are legitimate and stripped first.
  local badq
  badq="$(printf '%s' "$body" | sed "s/'''//g; s/''\\\${/\${/g" \
          | grep -n "^[[:space:]][[:space:]]*#.*''" || true)"
  [ -z "$badq" ] || fail "$t: comment inside an indented string contains a bare '' → $badq"

  # --- cheap Nix sanity: balanced brackets outside comments -----------------
  python3 - "$f" <<'PY' || fail "$t: unbalanced brackets"
import sys, re
s = re.sub(r'#.*', '', open(sys.argv[1]).read())
st, pairs = [], {'(': ')', '{': '}', '[': ']'}
close = {v: k for k, v in pairs.items()}
for ch in s:
    if ch in pairs: st.append(ch)
    elif ch in close:
        if not st or pairs[st[-1]] != ch: sys.exit(1)
        st.pop()
sys.exit(0 if not st else 1)
PY

  # --- any service that serves the declared port must be reachable ----------
  # (binding localhost would be invisible to the reverse proxy container)
  if printf '%s' "$body" | grep -qE 'astro dev|wrangler dev|--host|--ip'; then
    printf '%s' "$body" | grep -qE '\-\-host 0\.0\.0\.0|\-\-ip 0\.0\.0\.0|HOST="0\.0\.0\.0"' \
      || fail "$t: dev server must bind 0.0.0.0 to be proxy-reachable"
  fi
}
