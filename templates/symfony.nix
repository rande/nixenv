# nixenv:description  Symfony 7 + PHP 8.3 + nginx + PostgreSQL (composer, symfony-cli)
# nixenv:port         8000
# nixenv:allow        repo.packagist.org packagist.org api.github.com codeload.github.com github.com .githubusercontent.com getcomposer.org .symfony.com
# =============================================================================
# nixenv template — Symfony (symfony-standard)
# =============================================================================
#   ./nixenv.sh init myapp --template=symfony
#   ./nixenv.sh run  myapp         →  https://myapp-8000.nixenv.localhost/
#
#   # existing Symfony repo (skeleton step is skipped, composer install runs):
#   ./nixenv.sh init myapp git@github.com:me/app.git
#   # …then add this file as flake.nix and: ./nixenv.sh build myapp
#
#   # from a local checkout / your own fork:
#   ./nixenv.sh init myapp --template=./templates/symfony.nix
# -----------------------------------------------------------------------------
#
# WHAT THIS FILE IS
#   The project's flake.nix. It declares the TOOLCHAIN only (php, composer,
#   symfony-cli, nginx, postgresql). The application is created ONCE on first
#   start by the hook — `composer create-project symfony/skeleton` — so you get
#   ordinary editable files in the app volume that you can git-commit. A Nix
#   build is sandboxed to its own $out and can never write the app volume.
#
# SERVICES   postgresql, php-fpm, nginx — supervised by runit (`sv status …`)
# DATA       /databases/pgsql (persistent volume)
# DB URL     postgresql://app@localhost/app?serverVersion=16 (written to .env.local)
# =============================================================================
{
  description = "Symfony dev environment (nixenv template)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # --- Tunables ---------------------------------------------------------
      httpPort = "8000";        # must match `# nixenv:port` above
      dbName   = "app";
      dbUser   = "app";
      # "webapp" pulls in twig/asset-mapper/etc; "skeleton" stays minimal.
      # Set to "" to skip project creation entirely (bring your own code).
      skeleton = "symfony/skeleton";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
          php  = pkgs.php83.buildEnv {
            extensions = { enabled, all }: enabled ++ (with all; [
              pdo_pgsql pgsql intl opcache mbstring zip xsl gd
              apcu sodium curl dom tokenizer
            ]);
            extraConfig = ''
              memory_limit = 1G
              display_errors = On
              error_reporting = E_ALL
              date.timezone = UTC
              realpath_cache_size = 4096K
              opcache.enable_cli = 1
            '';
          };

          nginxConf = pkgs.writeTextDir "etc/nginx.conf" ''
            worker_processes 1;
            error_log /dev/stderr info;
            pid /home/app/.nixenv-run/nginx.pid;
            events { worker_connections 256; }
            http {
              include ${pkgs.nginx}/conf/mime.types;
              default_type application/octet-stream;
              access_log /dev/stdout;
              client_body_temp_path /home/app/.nixenv-run/nginx-body;
              proxy_temp_path       /home/app/.nixenv-run/nginx-proxy;
              fastcgi_temp_path     /home/app/.nixenv-run/nginx-fastcgi;
              uwsgi_temp_path       /home/app/.nixenv-run/nginx-uwsgi;
              scgi_temp_path        /home/app/.nixenv-run/nginx-scgi;
              client_max_body_size 32m;
              server {
                listen ${httpPort};
                server_name _;
                root @@APP_MOUNT@@/public;
                # Symfony front controller
                location / { try_files $uri /index.php$is_args$args; }
                location ~ ^/index\.php(/|$) {
                  include ${pkgs.nginx}/conf/fastcgi_params;
                  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                  fastcgi_param DOCUMENT_ROOT $document_root;
                  # TLS is terminated by nixenv's reverse proxy
                  fastcgi_param HTTPS $http_x_forwarded_proto;
                  fastcgi_pass unix:/home/app/.nixenv-run/php-fpm.sock;
                  internal;
                }
                location ~ \.php$ { return 404; }
              }
            }
          '';

          phpFpmConf = pkgs.writeTextDir "etc/php-fpm.conf" ''
            [global]
            error_log = /dev/stderr
            daemonize = no
            [www]
            listen = /home/app/.nixenv-run/php-fpm.sock
            pm = dynamic
            pm.max_children = 10
            pm.start_servers = 2
            pm.min_spare_servers = 1
            pm.max_spare_servers = 3
            catch_workers_output = yes
            php_admin_value[error_log] = /dev/stderr
            clear_env = no
          '';

          # --- Services -------------------------------------------------------
          # Declared as FILES in the profile at sv/<name>/run; nixenv copies them
          # into ~/.nixenv-sv on every start and runit supervises each one. Each
          # must exec a FOREGROUND process.
          svPostgres = pkgs.writeTextDir "sv/postgresql/run" ''
            #!/bin/sh
            mkdir -p "$HOME/.nixenv-run"
            [ -f /databases/pgsql/PG_VERSION ] || { echo "postgres: cluster not initialised yet"; sleep 5; exit 0; }
            exec postgres -D /databases/pgsql -k "$HOME/.nixenv-run" -h 127.0.0.1 -p 5432
          '';
          svPhpFpm = pkgs.writeTextDir "sv/php-fpm/run" ''
            #!/bin/sh
            mkdir -p "$HOME/.nixenv-run"
            exec php-fpm -F -y "$NIXENV_EXTRA_PROFILE/etc/php-fpm.conf"
          '';
          svNginx = pkgs.writeTextDir "sv/nginx/run" ''
            #!/bin/sh
            mkdir -p "$HOME/.nixenv-run"
            i=0; while [ ! -S "$HOME/.nixenv-run/php-fpm.sock" ] && [ $i -lt 30 ]; do
              i=$((i+1)); sleep 1; done
            exec nginx -g 'daemon off;' -c "$NIXENV_EXTRA_PROFILE/etc/nginx.conf" -p "$HOME/.nixenv-run"
          '';

          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_pre_ssh_start() {
              APP="''${NIXENV_APP_MOUNT:-/app}"
              RUN="$HOME/.nixenv-run"
              MARK="$APP/.nixenv/.symfony-installed"
              PGDATA=/databases/pgsql
              mkdir -p "$RUN" "$APP/.nixenv"

              # ---- database cluster (once) ---------------------------------
              if [ ! -f "$PGDATA/PG_VERSION" ]; then
                echo "nixenv/symfony: initialising PostgreSQL…"
                mkdir -p "$PGDATA"
                initdb -D "$PGDATA" -U "${dbUser}" --auth=trust --encoding=UTF8 >/dev/null
              fi

              [ -f "$MARK" ] && return 0

              echo "nixenv/symfony: first-run setup…"
              # A previous failed setup can leave a stale pid file behind; no
              # server can be running yet (services start after this hook).
              [ -f "$PGDATA/postmaster.pid" ] && pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 \
                || rm -f "$PGDATA/postmaster.pid"
              pg_ctl -D "$PGDATA" -o "-k $RUN -h 127.0.0.1 -p 5432" -l /tmp/pg-setup.log -w start || {
                echo "nixenv/symfony: postgres failed to start; see /tmp/pg-setup.log"; return 1; }
              createdb -h 127.0.0.1 -U "${dbUser}" "${dbName}" 2>/dev/null || true

              # ---- Symfony project (composer, one time) --------------------
              # composer create-project needs an EMPTY target, but $APP already
              # holds flake.nix/.nixenv — so build in a scratch dir and copy in.
              # That dir must be somewhere writable: NOT "$APP.tmp" (which with
              # APP=/app means /app.tmp at the filesystem root, where the non-root
              # app user cannot write).
              if [ -n "${skeleton}" ] && [ ! -f "$APP/composer.json" ]; then
                echo "nixenv/symfony: creating ${skeleton}…"
                SKEL="$RUN/skeleton"
                rm -rf "$SKEL"
                composer create-project --no-interaction --no-progress "${skeleton}" "$SKEL" || {
                  echo "nixenv/symfony: composer failed — is repo.packagist.org allowed? (nixenv egress $NIXENV_PROJECT)"
                  pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1; return 1; }
                # copy contents (including dotfiles) into the mounted volume
                ( cd "$SKEL" && tar cf - . ) | ( cd "$APP" && tar xf - )
                rm -rf "$SKEL"
                # Fail LOUDLY rather than leaving an empty project behind.
                [ -f "$APP/composer.json" ] || {
                  echo "nixenv/symfony: composer.json missing after create-project — setup aborted"
                  pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1; return 1; }
              elif [ -f "$APP/composer.json" ] && [ ! -d "$APP/vendor" ]; then
                echo "nixenv/symfony: installing composer dependencies…"
                ( cd "$APP" && composer install --no-interaction --no-progress ) || true
              fi

              # ---- local env (never overwrite an existing .env.local) ------
              if [ ! -f "$APP/.env.local" ]; then
                cat > "$APP/.env.local" <<ENVL
            # Written once by the nixenv symfony template — edit freely.
            APP_ENV=dev
            APP_DEBUG=1
            DATABASE_URL="postgresql://${dbUser}@127.0.0.1:5432/${dbName}?serverVersion=16&charset=utf8"
            ENVL
              fi

              pg_ctl -D "$PGDATA" -w stop >/dev/null 2>&1 || true
              touch "$MARK"
              echo "nixenv/symfony: ready → https://@@PROJECT@@-${httpPort}.@@DOMAIN@@/"
              echo "nixenv/symfony: console → 'php bin/console' (run from $APP)"
            }
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "symfony-project";
            extraOutputsToInstall = [ "man" ];
            paths = [
              php
              php.packages.composer
              pkgs.symfony-cli
              pkgs.nginx
              pkgs.postgresql_16
              pkgs.nodejs_22        # asset-mapper / encore / tailwind builds
              nginxConf
              phpFpmConf
              svPostgres svPhpFpm svNginx   # → ~/.nixenv-sv/<name>, run by runit
              startupHook
            ];
          };
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in { default = pkgs.mkShell { packages = [ self.packages.${system}.default ]; }; });
    };
}
