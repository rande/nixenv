# nixenv:description  Windmill self-hosted — server + workers + PostgreSQL (no docker-compose)
# nixenv:port         8000
# nixenv:allow        .windmill.dev pypi.org .pythonhosted.org .npmjs.org deno.land .deno.land jsr.io esm.sh .golang.org .nuget.org github.com codeload.github.com .githubusercontent.com
# =============================================================================
# nixenv template — Windmill (https://windmill.dev), self-hosted
# =============================================================================
#   ./nixenv.sh init flows --template=windmill
#   ./nixenv.sh run  flows         →  https://flows-8000.nixenv.localhost/
#
#   # from a local checkout / your own fork:
#   ./nixenv.sh init flows --template=./templates/windmill.nix
#
#   First login: admin@windmill.dev / changeme  (change it immediately)
# -----------------------------------------------------------------------------
#
# WHAT THIS FILE IS
#   The project's flake.nix. It replaces Windmill's upstream docker-compose
#   stack with runit services in ONE container. The nixpkgs `windmill` package
#   is a single binary that already embeds the frontend (`static_frontend`) and
#   is wrapped with PYTHON_PATH/DENO_PATH/BUN_PATH/GO_PATH/PHP_PATH/…, so job
#   runtimes come from the package itself — nothing extra on PATH.
#
# SERVICES   postgresql, windmill-server, windmill-worker, windmill-worker-native
#            (supervised by runit — `sv status ~/.nixenv-sv/*`)
# DATA       /databases/pgsql          (persistent volume)
# DB URL     postgres://app@127.0.0.1:5432/windmill
#
# WHERE YOUR WORK LIVES — READ THIS
#   Unlike every other nixenv template, the app volume does NOT hold the app.
#   Windmill keeps flows, scripts and apps as rows in PostgreSQL, so /app starts
#   with just flake.nix and a README, and nothing is ever written there
#   automatically. Files appear only when you run `wmill sync pull`.
#
#   The `wmill` CLI is on PATH (it is not in nixpkgs, so it runs from JSR via the
#   deno already inside the windmill closure). One SERVER hosts as many
#   workspaces as you want — create them in the UI. `wmill sync` is scoped to the
#   current directory AND the selected workspace, so the layout is one directory
#   per workspace, with the app volume as the git repo:
#
#       /app/workspaces/main/     wmill.yaml + f/<folder>/…
#       /app/workspaces/staging/  wmill.yaml + f/<folder>/…
#
#   Sync is stateless and destructive in both directions — it makes the target
#   match the source. It is a deliberate publish/fetch step, never a live mirror,
#   which is why nothing here runs it for you. Full recipe in the README the hook
#   writes into /app.
#
# WHICH VERSION YOU GET
#   Default: `pkgs.windmill` from the pinned nixpkgs. Prebuilt on Hydra, works on
#   x86_64 AND aarch64, and every job runtime is already wrapped in. But nixpkgs
#   lags upstream a long way (26.05 and unstable both carry 1.601.1 while
#   upstream is past 1.79x), so you are choosing "cached and stable, months old".
#
#   For the LATEST release, flip `useUpstreamBinary = true` below and set
#   `upstreamVersion` / `upstreamSha256` from
#     https://api.github.com/repos/windmill-labs/windmill/releases/latest
#     → .tag_name, and .assets[] where name == "windmill-amd64" → .digest
#   That path is x86_64-linux ONLY (upstream ships no arm64 asset) and drops
#   C#/PowerShell job support, which the nixpkgs wrapper provides. It is NOT
#   exercised by the test suite — treat the first build as a trial.
#
#   Bumping the pinned nixpkgs (`nix flake update` in the project flake dir)
#   does NOT help here: unstable carries the same 1.601.1.
#
# HEADS UP — this is a BIG closure. The wrapper pulls in deno, bun, go,
#   python312, php, powershell, dotnet-sdk and nsjail, so expect several GB on
#   the first `./nixenv.sh build <project>`. It downloads from cache.nixos.org
#   rather than compiling, and the builder is not egress-restricted, but it is
#   not a quick first run. The shared store means a SECOND windmill project
#   costs nothing extra.
#
# NOT INCLUDED (upstream compose has these; add them if you need them)
#   - windmill-extra (LSP / multiplayer / debugger): a separate OCI image, so it
#     has no nixpkgs equivalent. Editor autocomplete in the web UI is degraded.
#   - the indexer (full-text job search) — an Enterprise feature.
#   - upstream's caddy-l4 — nixenv's own reverse proxy already fronts port 8000.
#     SMTP-triggered jobs (port 25) are not wired up.
# =============================================================================
{
  description = "Windmill self-hosted (nixenv template)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # --- Tunables -----------------------------------------------------------
      httpPort = "8000";        # must match `# nixenv:port` above
      dbName   = "windmill";
      dbUser   = "app";         # the container's login user IS the pg superuser
      dbUrl    = "postgres://${dbUser}@127.0.0.1:5432/${dbName}";
      logLevel = "info";        # error | warn | info | debug | trace
      # Windmill builds webhook/OAuth callback URLs from this, so it has to be
      # the URL you actually reach the UI on — not localhost.
      baseUrl  = "https://@@PROJECT@@-${httpPort}.@@DOMAIN@@";

      # --- Latest upstream release instead of nixpkgs (see header) ------------
      # x86_64-linux only; no C#/PowerShell executors. Refresh both values from
      # the releases API together — a stale hash fails the build immediately,
      # which is the point of pinning.
      useUpstreamBinary = false;
      upstreamVersion   = "1.798.0";
      upstreamSha256    = "8dd41341d300f11272ae31511081113f300ea885091501ae0a81aee93341a444";

      # --- wmill CLI (git sync) ----------------------------------------------
      # Not in nixpkgs, so it runs straight from JSR via deno — which is already
      # in the windmill closure, making this near-free. Append a version
      # (…/wmill@1.601.1) to pin it; bare means latest at first run, cached in
      # DENO_DIR from then on.
      wmillSpec = "jsr:@windmill-labs/wmill";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

          # --- Which windmill binary --------------------------------------------
          # The upstream release asset is one self-contained ELF (it embeds the
          # frontend). autoPatchelfHook rewrites its interpreter/rpath for the
          # nix store; wrapProgram supplies the job runtimes the same way the
          # nixpkgs derivation does. Same prebuilt-binary trick the base flake
          # uses for zmx, for the same reason: building from source here is not
          # practical.
          windmillUpstream = pkgs.stdenv.mkDerivation {
            pname = "windmill-bin";
            version = upstreamVersion;
            src = pkgs.fetchurl {
              url = "https://github.com/windmill-labs/windmill/releases/download/v${upstreamVersion}/windmill-amd64";
              sha256 = upstreamSha256;
            };
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
            buildInputs = [
              pkgs.openssl pkgs.zlib pkgs.libxml2 pkgs.xmlsec pkgs.libxslt
              (pkgs.lib.getLib pkgs.stdenv.cc.cc)
            ];
            installPhase = ''
              runHook preInstall
              install -Dm755 "$src" "$out/bin/windmill"
              runHook postInstall
            '';
            postFixup = ''
              wrapProgram "$out/bin/windmill" \
                --set PYTHON_PATH ${pkgs.python312}/bin/python3 \
                --set UV_PATH     ${pkgs.uv}/bin/uv \
                --set DENO_PATH   ${pkgs.deno}/bin/deno \
                --set BUN_PATH    ${pkgs.bun}/bin/bun \
                --set GO_PATH     ${pkgs.go}/bin/go \
                --set PHP_PATH    ${pkgs.php}/bin/php \
                --set FLOCK_PATH  ${pkgs.flock}/bin/flock \
                --set BASH_PATH   ${pkgs.bash}/bin/bash \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.python312 pkgs.procps pkgs.coreutils ]}
            '';
            meta.mainProgram = "windmill";
          };

          windmillPkg =
            if !useUpstreamBinary then pkgs.windmill
            else if system != "x86_64-linux" then
              throw ("windmill template: useUpstreamBinary is x86_64-linux only "
                     + "(upstream ships no arm64 asset) — set it back to false for ${system}")
            else windmillUpstream;

          # --- wmill CLI --------------------------------------------------------
          # `wmill sync` is scoped to the CURRENT DIRECTORY and the currently
          # selected workspace, which is why the scaffold below gives each
          # workspace its own directory under the app volume.
          wmillCli = pkgs.writeShellScriptBin "wmill" ''
            export DENO_DIR="''${DENO_DIR:-$HOME/.cache/deno}"
            mkdir -p "$DENO_DIR"
            exec ${pkgs.deno}/bin/deno run -A --unstable-worker-options ${wmillSpec} "$@"
          '';

          # --- Services ---------------------------------------------------------
          # Declared as FILES in the profile at sv/<name>/run; nixenv copies them
          # into ~/.nixenv-sv on every start and runit supervises each one. Each
          # must exec a FOREGROUND process. A service that exits is retried by
          # runsv, so `sleep N; exit 0` is how we wait for a dependency.
          svPostgres = pkgs.writeTextDir "sv/postgresql/run" ''
            #!/bin/sh
            exec 2>&1
            mkdir -p "$HOME/.nixenv-run"
            [ -f /databases/pgsql/PG_VERSION ] || { echo "postgres: cluster not initialised yet"; sleep 5; exit 0; }
            exec postgres -D /databases/pgsql -k "$HOME/.nixenv-run" -h 127.0.0.1 -p 5432
          '';

          # MODE=server serves the API *and* the embedded web UI on $PORT.
          svServer = pkgs.writeTextDir "sv/windmill-server/run" ''
            #!/bin/sh
            exec 2>&1
            pg_isready -h 127.0.0.1 -p 5432 -q || { echo "windmill-server: waiting for postgres"; sleep 5; exit 0; }
            mkdir -p "$HOME/.nixenv-run/windmill"
            export DATABASE_URL="${dbUrl}"
            export MODE=server
            export PORT=${httpPort}
            export WM_BASE_URL="${baseUrl}"
            export RUST_LOG=${logLevel}
            exec windmill
          '';

          # The default worker group runs "heavy" jobs (python/deno/bun/go/php…).
          # DISABLE_NSJAIL: nsjail needs privileges this non-root, unprivileged
          # container does not have. Jobs therefore run UNSANDBOXED, as the app
          # user, with the project's egress rules as the only boundary. Fine for
          # a dev box you own; do not treat it as multi-tenant isolation.
          svWorker = pkgs.writeTextDir "sv/windmill-worker/run" ''
            #!/bin/sh
            exec 2>&1
            pg_isready -h 127.0.0.1 -p 5432 -q || { echo "windmill-worker: waiting for postgres"; sleep 5; exit 0; }
            mkdir -p "$HOME/.nixenv-run/windmill"
            export DATABASE_URL="${dbUrl}"
            export MODE=worker
            export WORKER_GROUP=default
            export KEEP_JOB_DIR=false
            export DISABLE_NSJAIL=true
            export RUST_LOG=${logLevel}
            export WM_BASE_URL="${baseUrl}"
            exec windmill
          '';

          # "native" jobs run in-process and are far lighter than the above.
          svWorkerNative = pkgs.writeTextDir "sv/windmill-worker-native/run" ''
            #!/bin/sh
            exec 2>&1
            pg_isready -h 127.0.0.1 -p 5432 -q || { echo "windmill-worker-native: waiting for postgres"; sleep 5; exit 0; }
            mkdir -p "$HOME/.nixenv-run/windmill"
            export DATABASE_URL="${dbUrl}"
            export MODE=worker
            export WORKER_GROUP=native
            export NATIVE_MODE=true
            export SLEEP_QUEUE=200
            export DISABLE_NSJAIL=true
            export RUST_LOG=${logLevel}
            export WM_BASE_URL="${baseUrl}"
            exec windmill
          '';

          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_pre_ssh_start() {
              APP="''${NIXENV_APP_MOUNT:-/app}"
              RUN="$HOME/.nixenv-run"
              MARK="$APP/.nixenv/.windmill-installed"
              PGDATA=/databases/pgsql
              PSQL="psql -h 127.0.0.1 -p 5432 -U ${dbUser} -v ON_ERROR_STOP=0 -q"
              mkdir -p "$RUN" "$APP/.nixenv"

              # ---- database cluster (once) ---------------------------------
              if [ ! -f "$PGDATA/PG_VERSION" ]; then
                echo "nixenv/windmill: initialising PostgreSQL…"
                mkdir -p "$PGDATA"
                initdb -D "$PGDATA" -U "${dbUser}" --auth=trust --encoding=UTF8 >/dev/null
              fi

              [ -f "$MARK" ] && return 0

              echo "nixenv/windmill: first-run setup…"
              # A previous failed setup can leave a stale pid file behind; no
              # server can be running yet (services start after this hook).
              [ -f "$PGDATA/postmaster.pid" ] && pg_isready -h 127.0.0.1 -p 5432 -q \
                || rm -f "$PGDATA/postmaster.pid"
              pg_ctl -D "$PGDATA" -o "-k $RUN -h 127.0.0.1 -p 5432" -l /tmp/pg-setup.log -w start || {
                echo "nixenv/windmill: postgres failed to start; see /tmp/pg-setup.log"; return 1; }

              createdb -h 127.0.0.1 -p 5432 -U "${dbUser}" "${dbName}" 2>/dev/null || true

              # Windmill's migrations expect the windmill_user / windmill_admin
              # roles to exist already — upstream ships this as
              # init-db-as-superuser.sql and it must run as a superuser, which
              # is what ${dbUser} is (it created the cluster).
              # Written as separate idempotent statements on purpose: a DO $$…$$
              # block would need a shell heredoc inside a Nix indented string,
              # where indentation stripping can silently break the terminator.
              $PSQL -d "${dbName}" -c "CREATE ROLE windmill_user"                                >/dev/null 2>&1 || true
              $PSQL -d "${dbName}" -c "CREATE ROLE windmill_admin WITH BYPASSRLS"                >/dev/null 2>&1 || true
              $PSQL -d "${dbName}" -c "GRANT ALL PRIVILEGES ON DATABASE ${dbName} TO windmill_user" >/dev/null 2>&1 || true
              $PSQL -d "${dbName}" -c "GRANT windmill_user TO windmill_admin"                    >/dev/null 2>&1 || true
              $PSQL -d "${dbName}" -c "GRANT windmill_admin TO ${dbUser}"                        >/dev/null 2>&1 || true

              # Fail LOUDLY rather than letting the server start against a
              # database that will reject its migrations.
              $PSQL -d "${dbName}" -tAc "SELECT 1 FROM pg_roles WHERE rolname='windmill_admin'" 2>/dev/null | grep -q 1 || {
                echo "nixenv/windmill: could not create the windmill_admin role — setup aborted"
                pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1; return 1; }

              # ---- git-sync scaffold ---------------------------------------
              # Windmill stores flows/scripts in PostgreSQL, NOT on disk. Files
              # only appear here when you run `wmill sync pull`. That command is
              # scoped to the current directory and the selected workspace, so
              # each workspace gets its own directory: the app volume is the git
              # repo, workspaces/<name> is a sync root.
              mkdir -p "$APP/workspaces"
              if [ ! -f "$APP/.gitignore" ]; then
                printf '%s\n' \
                  "# nixenv/windmill" \
                  ".nixenv/" \
                  ".deno/" \
                  "node_modules/" \
                  "*.log" \
                  > "$APP/.gitignore"
              fi

              # printf, not a heredoc: heredocs nested in a Nix indented string
              # are fragile (see CLAUDE.md → "Writing templates — hard-won rules").
              if [ ! -f "$APP/README.windmill.md" ]; then
                printf '%s\n' \
                  "# @@PROJECT@@ — Windmill" \
                  "" \
                  "  UI      https://@@PROJECT@@-${httpPort}.@@DOMAIN@@/" \
                  "  login   admin@windmill.dev / changeme   <- change this now" \
                  "  logs    ./nixenv.sh logs @@PROJECT@@" \
                  "  status  sv status ~/.nixenv-sv/windmill-server" \
                  "" \
                  "## Where your work lives" \
                  "" \
                  "Flows, scripts and apps are rows in PostgreSQL (/databases/pgsql), not" \
                  "files. Nothing here is written automatically. Losing the databases volume" \
                  "loses the workspace, so pull into git regularly." \
                  "" \
                  "## Versioning a workspace" \
                  "" \
                  "Create workspaces in the UI (the server hosts as many as you like), then" \
                  "give each one a directory here — 'wmill sync' acts on the CURRENT" \
                  "directory and the CURRENTLY SELECTED workspace:" \
                  "" \
                  "    cd workspaces && mkdir -p main && cd main" \
                  "    wmill workspace add main <workspace-id> http://127.0.0.1:${httpPort}/" \
                  "    wmill init                # writes wmill.yaml (includes/excludes)" \
                  "    wmill sync pull           # workspace -> files, under f/<folder>/" \
                  "" \
                  "Then commit /app as usual. To switch: 'wmill workspace switch <name>'," \
                  "and cd to that workspace's directory before syncing." \
                  "" \
                  "CAUTION: sync is stateless and destructive in BOTH directions — it makes" \
                  "the target match the source, deleting anything the source lacks. Commit" \
                  "before 'pull', and review the diff before 'push'." \
                  > "$APP/README.windmill.md"
              fi

              pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1 || true
              touch "$MARK"
              echo "nixenv/windmill: ready → ${baseUrl}/"
              echo "nixenv/windmill: first login admin@windmill.dev / changeme (change it)"
            }
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "windmill-project";
            extraOutputsToInstall = [ "man" ];
            paths = [
              windmillPkg
              wmillCli                # `wmill` — git sync, see README.windmill.md
              pkgs.postgresql_16
              svPostgres svServer svWorker svWorkerNative   # → ~/.nixenv-sv/<name>
              startupHook
            ];
          };
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in { default = pkgs.mkShell { packages = [ self.packages.${system}.default ]; }; });
    };
}
