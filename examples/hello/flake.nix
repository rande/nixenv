# nixenv:description  Hello world — nginx serving one static page
# nixenv:port         8080
# =============================================================================
# examples/hello — the smallest useful nixenv project
# =============================================================================
#   ./nixenv.sh init hello --template=examples/hello/flake.nix --yes
#   ./nixenv.sh run  hello        →  https://hello-8080.nixenv.localhost/
#
# Used by DEVELOPING.md as the project you boot INSIDE a nixenv dev project
# (nested engines), and handy as a smoke test anywhere else: it needs no network
# after the build, no database, and nothing in the app volume.
#
# WHAT IT SHOWS
#   * a service declared as a FILE (sv/hello/run) — nixenv's entrypoint copies
#     it into ~/.nixenv-sv and runit keeps it alive;
#   * nginx configured for a non-root container: every writable path is under
#     /home/app/.nixenv-run (nginx does not expand $HOME in its config), and it
#     listens on 0.0.0.0 so the reverse proxy — another container — can reach it;
#   * the page itself lives in the Nix store: read-only, versioned with the flake.
#
# No `# nixenv:allow` line: after the build, this project needs no network.
# =============================================================================
{
  description = "nixenv example: nginx hello world";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      httpPort = "8080";   # must match `# nixenv:port` above
      run = "/home/app/.nixenv-run/hello";
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };

          site = pkgs.writeTextDir "share/hello/index.html" ''
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>hello from nixenv</title>
            <style>
              body { font: 18px/1.5 system-ui, sans-serif; margin: 15vh auto; max-width: 34em; padding: 0 1em; }
              code { background: #eef; padding: .1em .3em; border-radius: 3px; }
            </style></head>
            <body>
              <h1>Hello from nixenv</h1>
              <p>This page is served by <code>nginx</code> from the Nix store, inside a
                 project container, supervised by <code>runit</code>.</p>
              <p id="ok">nixenv-hello-ok</p>
            </body>
            </html>
          '';

          nginxConf = pkgs.writeTextDir "etc/hello-nginx.conf" ''
            worker_processes 1;
            error_log ${run}/error.log;
            pid ${run}/nginx.pid;
            events { worker_connections 64; }
            http {
              include ${pkgs.nginx}/conf/mime.types;
              default_type application/octet-stream;
              access_log ${run}/access.log;
              client_body_temp_path ${run}/tmp/body;
              proxy_temp_path       ${run}/tmp/proxy;
              fastcgi_temp_path     ${run}/tmp/fastcgi;
              uwsgi_temp_path       ${run}/tmp/uwsgi;
              scgi_temp_path        ${run}/tmp/scgi;
              server {
                listen 0.0.0.0:${httpPort};
                server_name _;
                root ${site}/share/hello;
                index index.html;
              }
            }
          '';

          # A foreground process; runit restarts it if it dies. `-e` sends the
          # startup log somewhere writable before the config is even read (the
          # compiled-in default is under /var/log, which `app` can't write).
          svHello = pkgs.writeTextDir "sv/hello/run" ''
            #!/bin/sh
            mkdir -p ${run}/tmp
            exec nginx -e ${run}/error.log -p ${run} \
              -c "$NIXENV_EXTRA_PROFILE/etc/hello-nginx.conf" -g 'daemon off;'
          '';

          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_pre_ssh_start() {
              mkdir -p ${run}/tmp
            }
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "nixenv-hello";
            paths = [ pkgs.nginx site nginxConf svHello startupHook ];
          };
        });
    };
}
