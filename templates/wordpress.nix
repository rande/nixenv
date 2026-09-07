# nixenv:description  WordPress + PHP 8.3 + nginx + MariaDB (wp-cli installed)
# nixenv:port         8080
# nixenv:allow        wordpress.org api.wordpress.org downloads.wordpress.org .w.org
# =============================================================================
# nixenv template — WordPress
# =============================================================================
#   ./nixenv.sh init myblog --template=wordpress
#   ./nixenv.sh run  myblog        →  https://myblog-8080.nixenv.localhost/
#
#   # from a local checkout / your own fork:
#   ./nixenv.sh init myblog --template=./templates/wordpress.nix
#   ./nixenv.sh init myblog --template=https://example.com/wordpress.nix
# -----------------------------------------------------------------------------
#
# WHAT THIS FILE IS
#   The project's flake.nix. It declares only the TOOLCHAIN (php, nginx,
#   mariadb, wp-cli) plus config files and a startup hook. WordPress itself is
#   NOT vendored here: the hook runs `wp core download` + `wp core install` ONCE
#   on first start, so the resulting site is ordinary editable files in the app
#   volume — exactly like a hand-made WordPress project you can git-commit.
#
#   A Nix build is sandboxed and can only write to its own $out, so it can never
#   populate the app volume; the startup hook is the supported way to do runtime
#   setup. Re-runs are no-ops thanks to a marker file.
#
# LOGINS       admin / admin   (change immediately if this is ever exposed)
# SERVICES     mariadb, php-fpm, nginx — supervised by runit, see `sv status`
# DATA         /databases/mysql  (persistent volume, survives container rebuild)
# =============================================================================
{
  description = "WordPress dev environment (nixenv template)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # --- Tunables ---------------------------------------------------------
      wpVersion = "latest";          # or "6.7.1" to pin
      httpPort  = "8080";            # must match `# nixenv:port` above
      dbName    = "wordpress";
      # Installed + activated on first run. Add/remove freely, then:
      #   nixenv build <project> && nixenv stop <project> && nixenv run <project>
      # (existing installs keep their plugins — the marker skips re-setup)
      wpPlugins = [ "query-monitor" "wp-crontrol" ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
          php  = pkgs.php83.buildEnv {
            extensions = { enabled, all }: enabled ++ (with all; [
              mysqli pdo_mysql gd intl zip mbstring exif opcache
            ]);
            extraConfig = ''
              memory_limit = 512M
              upload_max_filesize = 64M
              post_max_size = 64M
              display_errors = On
              error_reporting = E_ALL
            '';
          };

          # nginx: one server block, PHP-FPM over a socket in $HOME (writable).
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
              client_max_body_size 64m;
              server {
                listen ${httpPort};
                server_name _;
                root @@APP_MOUNT@@;
                index index.php;
                # The reverse proxy terminates TLS; trust its forwarded scheme
                # so WordPress builds https:// URLs.
                location / { try_files $uri $uri/ /index.php?$args; }
                location ~ \.php$ {
                  include ${pkgs.nginx}/conf/fastcgi_params;
                  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                  fastcgi_param HTTPS $http_x_forwarded_proto;
                  fastcgi_pass unix:/home/app/.nixenv-run/php-fpm.sock;
                }
                location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
                  expires max; log_not_found off;
                }
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

          # ---------------------------------------------------------------
          # Startup hook — the ONLY place that can write to the app volume.
          # Runs as the app user before services start, with this profile on
          # PATH. Idempotent: everything heavy is behind the marker file.
          # ---------------------------------------------------------------
          # --- Services -------------------------------------------------------
          # Declared as FILES in the profile at sv/<name>/run; nixenv copies them
          # into ~/.nixenv-sv on every start and runit supervises each one. Each
          # must exec a FOREGROUND process. (Declaring them here rather than
          # writing them from the hook keeps the hook simple and avoids nesting
          # shell heredocs inside a Nix string.)
          svMariadb = pkgs.writeTextDir "sv/mariadb/run" ''
            #!/bin/sh
            exec mariadbd --datadir=/databases/mysql \
                 --socket="$HOME/.nixenv-run/mysql.sock" \
                 --bind-address=127.0.0.1 --port=3306
          '';
          svPhpFpm = pkgs.writeTextDir "sv/php-fpm/run" ''
            #!/bin/sh
            mkdir -p "$HOME/.nixenv-run"
            exec php-fpm -F -y "$NIXENV_EXTRA_PROFILE/etc/php-fpm.conf"
          '';
          svNginx = pkgs.writeTextDir "sv/nginx/run" ''
            #!/bin/sh
            mkdir -p "$HOME/.nixenv-run"
            # wait for php-fpm's socket so nginx doesn't spin on a missing upstream
            i=0; while [ ! -S "$HOME/.nixenv-run/php-fpm.sock" ] && [ $i -lt 30 ]; do
              i=$((i+1)); sleep 1; done
            exec nginx -g 'daemon off;' -c "$NIXENV_EXTRA_PROFILE/etc/nginx.conf" -p "$HOME/.nixenv-run"
          '';

          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_pre_ssh_start() {
              APP="''${NIXENV_APP_MOUNT:-/app}"
              RUN="$HOME/.nixenv-run"
              MARK="$APP/.nixenv/.wordpress-installed"
              DATA=/databases/mysql
              SOCK="$RUN/mysql.sock"
              mkdir -p "$RUN" "$APP/.nixenv"

              [ -f "$MARK" ] && return 0        # already installed → done

              echo "nixenv/wordpress: first-run setup (this takes a minute)…"

              # ---- database ------------------------------------------------
              if [ ! -d "$DATA/mysql" ]; then
                mkdir -p "$DATA"
                mariadb-install-db --datadir="$DATA" --auth-root-authentication-method=normal >/dev/null
              fi
              mariadbd --datadir="$DATA" --socket="$SOCK" --skip-networking >/tmp/mariadb-setup.log 2>&1 &
              _pid=$!
              _i=0; while [ ! -S "$SOCK" ] && [ $_i -lt 30 ]; do sleep 1; _i=$((_i+1)); done
              if [ ! -S "$SOCK" ]; then
                echo "nixenv/wordpress: mariadb did not start; see /tmp/mariadb-setup.log"; return 1
              fi
              mariadb --socket="$SOCK" -u root -e \
                "CREATE DATABASE IF NOT EXISTS ${dbName} CHARACTER SET utf8mb4;" || true

              # ---- WordPress (wp-cli, one time) ----------------------------
              WP="wp --path=$APP --allow-root"
              if [ ! -f "$APP/wp-load.php" ]; then
                $WP core download --version=${wpVersion} || {
                  echo "nixenv/wordpress: download failed — is downloads.wordpress.org allowed? (nixenv allow $NIXENV_PROJECT downloads.wordpress.org)"
                  mariadb-admin --socket="$SOCK" -u root shutdown 2>/dev/null || kill $_pid 2>/dev/null
                  return 1
                }
              fi
              [ -f "$APP/wp-config.php" ] || \
                $WP config create --dbname=${dbName} --dbuser=root --dbhost="localhost:$SOCK" \
                    --extra-php <<'PHP'
            define( 'WP_DEBUG', true );
            define( 'WP_DEBUG_LOG', true );
            define( 'WP_DEBUG_DISPLAY', false );
            define( 'SCRIPT_DEBUG', true );
            define( 'DISALLOW_FILE_EDIT', false );
            // Behind nixenv's reverse proxy: trust the forwarded scheme.
            if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
                $_SERVER['HTTPS'] = 'on';
            }
            PHP

              SITE="https://@@PROJECT@@-${httpPort}.@@DOMAIN@@"
              $WP core is-installed 2>/dev/null || \
                $WP core install --url="$SITE" --title="@@PROJECT@@" \
                    --admin_user=admin --admin_password=admin \
                    --admin_email=admin@example.com --skip-email

              for _p in ${builtins.concatStringsSep " " wpPlugins}; do
                $WP plugin is-installed "$_p" 2>/dev/null || $WP plugin install "$_p" --activate || \
                  echo "nixenv/wordpress: could not install plugin $_p (egress? see: nixenv egress $NIXENV_PROJECT)"
              done

              mariadb-admin --socket="$SOCK" -u root shutdown 2>/dev/null || kill $_pid 2>/dev/null
              sleep 1
              touch "$MARK"
              echo "nixenv/wordpress: ready → $SITE  (admin / admin)"
            }
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "wordpress-project";
            extraOutputsToInstall = [ "man" ];
            paths = [
              php
              pkgs.nginx
              pkgs.mariadb
              pkgs.wp-cli
              nginxConf
              phpFpmConf
              svMariadb svPhpFpm svNginx    # → ~/.nixenv-sv/<name>, run by runit
              startupHook
            ];
          };
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in { default = pkgs.mkShell { packages = [ self.packages.${system}.default ]; }; });
    };
}
