# nixenv:description  Headless CMS — Directus (API/admin) + Astro (frontend)
# nixenv:port         4321
# nixenv:allow        registry.npmjs.org .npmjs.org .npmjs.com registry.yarnpkg.com .yarnpkg.com github.com codeload.github.com .githubusercontent.com
# =============================================================================
# nixenv template — Directus + Astro
# =============================================================================
#   ./nixenv.sh init mysite --template=headlesscms-directus-astro
#   ./nixenv.sh run  mysite
#       frontend (Astro)   →  https://mysite-4321.nixenv.localhost/
#       CMS      (Directus)→  https://mysite-8055.nixenv.localhost/    admin@example.com / directus
#
#   # from a local checkout / your own fork:
#   ./nixenv.sh init mysite --template=./templates/headlesscms-directus-astro.nix
# -----------------------------------------------------------------------------
#
# WHAT THIS FILE IS
#   The project's flake.nix. It declares the TOOLCHAIN only (Node, PostgreSQL).
#   Both apps are installed ONCE on first start by the hook (npm), into two
#   folders in the app volume — ordinary editable files you can git-commit:
#
#       @@APP_MOUNT@@/cms/       Directus  (port 8055, PostgreSQL-backed)
#       @@APP_MOUNT@@/web/       Astro     (port 4321, talks to the CMS)
#
#   A Nix build is sandboxed to its own $out and can never write the app volume,
#   so runtime setup lives in the startup hook (marker-guarded → instant restarts).
#
# SERVICES   postgresql, directus, astro — supervised by runit (`sv status …`)
# DATA       /databases/pgsql (persistent volume)
# NOTE       Astro reaches the CMS in-container at http://127.0.0.1:8055 —
#            no proxy hop. Browser-side code should use the public CMS URL.
# =============================================================================
{
  description = "Directus + Astro headless CMS (nixenv template)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # --- Tunables ---------------------------------------------------------
      webPort   = "4321";      # Astro dev server (must match `# nixenv:port`)
      cmsPort   = "8055";      # Directus default
      dbName    = "directus";
      dbUser    = "directus";
      adminMail = "admin@example.com";
      adminPass = "directus";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

          # --- Services -------------------------------------------------------
          # Declared as FILES in the profile at sv/<name>/run; nixenv copies them
          # into ~/.nixenv-sv on every start and runit supervises each one. Each
          # must exec a FOREGROUND process; exiting makes runsv retry (the
          # sleeps below throttle that while first-run setup is still going).
          svPostgres = pkgs.writeTextDir "sv/postgresql/run" ''
            #!/bin/sh
            mkdir -p "$HOME/.nixenv-run"
            [ -f /databases/pgsql/PG_VERSION ] || { echo "postgres: cluster not initialised yet"; sleep 5; exit 0; }
            exec postgres -D /databases/pgsql -k "$HOME/.nixenv-run" -h 127.0.0.1 -p 5432
          '';
          svDirectus = pkgs.writeTextDir "sv/directus/run" ''
            #!/bin/sh
            cd "''${NIXENV_APP_MOUNT:-/app}/cms" 2>/dev/null || { echo "directus: not installed yet"; sleep 10; exit 0; }
            [ -d node_modules ] || { echo "directus: deps missing"; sleep 10; exit 0; }
            i=0; while ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; do
              i=$((i+1)); [ $i -gt 30 ] && { echo "directus: no database"; sleep 5; exit 0; }; sleep 1; done
            exec npx directus start
          '';
          svAstro = pkgs.writeTextDir "sv/astro/run" ''
            #!/bin/sh
            cd "''${NIXENV_APP_MOUNT:-/app}/web" 2>/dev/null || { echo "astro: not installed yet"; sleep 10; exit 0; }
            [ -d node_modules ] || { echo "astro: deps missing"; sleep 10; exit 0; }
            # --host is REQUIRED: the reverse proxy is another container, so
            # binding localhost would be unreachable.
            exec npx astro dev --host 0.0.0.0 --port ${webPort}
          '';

          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_pre_ssh_start() {
              APP="''${NIXENV_APP_MOUNT:-/app}"
              RUN="$HOME/.nixenv-run"
              MARK="$APP/.nixenv/.directus-astro-installed"
              PGDATA=/databases/pgsql
              mkdir -p "$RUN" "$APP/.nixenv"

              # ---- database cluster (once) ---------------------------------
              if [ ! -f "$PGDATA/PG_VERSION" ]; then
                echo "nixenv/directus: initialising PostgreSQL…"
                mkdir -p "$PGDATA"
                initdb -D "$PGDATA" -U "${dbUser}" --auth=trust --encoding=UTF8 >/dev/null
              fi

              [ -f "$MARK" ] && return 0

              echo "nixenv/directus+astro: first-run setup (a few minutes)…"
              pg_ctl -D "$PGDATA" -o "-k $RUN -h 127.0.0.1 -p 5432" -l /tmp/pg-setup.log -w start || {
                echo "nixenv/directus: postgres failed to start; see /tmp/pg-setup.log"; return 1; }
              createdb -h 127.0.0.1 -U "${dbUser}" "${dbName}" 2>/dev/null || true

              # ---- Directus (CMS) ------------------------------------------
              if [ ! -f "$APP/cms/package.json" ]; then
                echo "nixenv/directus: installing Directus…"
                mkdir -p "$APP/cms"
                ( cd "$APP/cms" && npm init -y >/dev/null && \
                  npm install directus --no-audit --no-fund ) || {
                  echo "nixenv/directus: npm install failed — check egress (nixenv egress $NIXENV_PROJECT)"
                  pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1; return 1; }
              fi

              # .env drives Directus entirely; written once, edit freely.
              if [ ! -f "$APP/cms/.env" ]; then
                cat > "$APP/cms/.env" <<ENVF
            # Written once by the nixenv directus+astro template.
            HOST="0.0.0.0"
            PORT=${cmsPort}
            PUBLIC_URL="https://@@PROJECT@@-${cmsPort}.@@DOMAIN@@"
            DB_CLIENT="pg"
            DB_HOST="127.0.0.1"
            DB_PORT="5432"
            DB_DATABASE="${dbName}"
            DB_USER="${dbUser}"
            DB_PASSWORD=""
            KEY="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            SECRET="$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            ADMIN_EMAIL="${adminMail}"
            ADMIN_PASSWORD="${adminPass}"
            CORS_ENABLED="true"
            CORS_ORIGIN="true"
            ENVF
              fi

              ( cd "$APP/cms" && npx directus bootstrap ) || \
                echo "nixenv/directus: bootstrap failed (see above)"

              # ---- Astro (frontend) ----------------------------------------
              if [ ! -f "$APP/web/package.json" ]; then
                echo "nixenv/astro: scaffolding the frontend…"
                mkdir -p "$APP/web/src/pages"
                cat > "$APP/web/package.json" <<'JSON'
            {
              "name": "@@PROJECT@@-web",
              "private": true,
              "type": "module",
              "scripts": {
                "dev": "astro dev --host 0.0.0.0",
                "build": "astro build",
                "preview": "astro preview --host 0.0.0.0"
              }
            }
            JSON
                cat > "$APP/web/astro.config.mjs" <<'MJS'
            import { defineConfig } from 'astro/config';
            export default defineConfig({
              server: { host: '0.0.0.0', port: ${webPort} },
            });
            MJS
                cat > "$APP/web/.env" <<ENVW
            # Server-side calls stay in-container (no proxy hop):
            DIRECTUS_URL="http://127.0.0.1:${cmsPort}"
            # Browser-side calls must use the public URL:
            PUBLIC_DIRECTUS_URL="https://@@PROJECT@@-${cmsPort}.@@DOMAIN@@"
            ENVW
                cat > "$APP/web/src/pages/index.astro" <<'ASTRO'
            ---
            // Server-rendered at dev time: fetch from Directus inside the container.
            const base = import.meta.env.DIRECTUS_URL ?? 'http://127.0.0.1:${cmsPort}';
            let status = 'unreachable';
            try {
              const r = await fetch(`${base}/server/health`);
              status = r.ok ? 'up' : `error ${r.status}`;
            } catch (e) { status = 'unreachable'; }
            ---
            <html lang="en">
              <head><meta charset="utf-8" /><title>@@PROJECT@@</title></head>
              <body style="font-family: system-ui; max-width: 40rem; margin: 4rem auto;">
                <h1>@@PROJECT@@</h1>
                <p>Astro frontend is running. Directus is <strong>{status}</strong>.</p>
                <ul>
                  <li>CMS admin: <a href="https://@@PROJECT@@-${cmsPort}.@@DOMAIN@@">open Directus</a></li>
                  <li>Edit this page: <code>web/src/pages/index.astro</code></li>
                </ul>
              </body>
            </html>
            ASTRO
                cat > "$APP/web/.gitignore" <<'GI'
            node_modules/
            dist/
            .astro/
            GI
                ( cd "$APP/web" && npm install astro --no-audit --no-fund ) || \
                  echo "nixenv/astro: npm install failed — check egress"
              elif [ ! -d "$APP/web/node_modules" ]; then
                ( cd "$APP/web" && npm install --no-audit --no-fund ) || true
              fi

              pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1 || true
              touch "$MARK"
              echo "nixenv: ready →  web  https://@@PROJECT@@-${webPort}.@@DOMAIN@@/"
              echo "nixenv:          cms  https://@@PROJECT@@-${cmsPort}.@@DOMAIN@@/  (${adminMail} / ${adminPass})"
            }
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "directus-astro-project";
            extraOutputsToInstall = [ "man" ];
            paths = [
              pkgs.nodejs_22
              pkgs.postgresql_16
              pkgs.jq
              svPostgres svDirectus svAstro   # → ~/.nixenv-sv/<name>, run by runit
              startupHook
            ];
          };
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in { default = pkgs.mkShell { packages = [ self.packages.${system}.default ]; }; });
    };
}
