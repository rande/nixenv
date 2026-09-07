# nixenv:description  Cloudflare Workers dev — wrangler + Node 22 (local mode)
# nixenv:port         8787
# nixenv:allow        registry.npmjs.org .cloudflare.com .workers.dev .npmjs.org
# =============================================================================
# nixenv template — Cloudflare Workers / wrangler
# =============================================================================
#   ./nixenv.sh init myworker --template=cloudflare
#   ./nixenv.sh run  myworker      →  https://myworker-8787.nixenv.localhost/
#
#   # existing Worker repo (scaffold is skipped, npm install runs instead):
#   ./nixenv.sh init myworker git@github.com:me/worker.git
#   # …then add this file as flake.nix and: ./nixenv.sh build myworker
#
#   # from a local checkout / your own fork:
#   ./nixenv.sh init myworker --template=./templates/cloudflare.nix
# -----------------------------------------------------------------------------
#
# WHAT THIS FILE IS
#   The project's flake.nix. It declares the TOOLCHAIN only (Node + wrangler).
#   On first start the hook scaffolds a minimal Worker into the app volume IF
#   it's empty — plain editable files you can git-commit — and registers
#   `wrangler dev` as a supervised service. Nothing is vendored into the store,
#   and a Nix build can't write the app volume anyway (it's sandboxed to $out).
#
#   Have an existing Worker repo? Use `nixenv init <p> <git-url>` and drop this
#   file in as flake.nix — the scaffold step is skipped when files exist, and
#   `npm install` runs instead if there's a package.json.
#
# LOCAL MODE   `wrangler dev` runs the Worker locally in workerd; no Cloudflare
#              account is needed. `wrangler login` (browser) is only required
#              for deploys and remote bindings.
# SERVICE      wrangler-dev — `sv status ~/.nixenv-sv/wrangler-dev`, logs via
#              `nixenv logs <project>`.
# =============================================================================
{
  description = "Cloudflare Workers dev environment (nixenv template)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # --- Tunables ---------------------------------------------------------
      devPort = "8787";              # must match `# nixenv:port` above
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

          # ---------------------------------------------------------------
          # Startup hook — the only place that can write to the app volume.
          # Scaffolds once (marker-guarded), then registers the dev service.
          # ---------------------------------------------------------------
          # --- Service --------------------------------------------------------
          # Declared as a FILE in the profile at sv/<name>/run; nixenv copies it
          # into ~/.nixenv-sv on every start and runit supervises it.
          # --ip 0.0.0.0 is REQUIRED: the reverse proxy is another container, so
          # binding 127.0.0.1 would be unreachable.
          svWrangler = pkgs.writeTextDir "sv/wrangler-dev/run" ''
            #!/bin/sh
            cd "''${NIXENV_APP_MOUNT:-/app}" || exit 1
            [ -f wrangler.toml ] || [ -f wrangler.jsonc ] || [ -f wrangler.json ] || {
              echo "wrangler-dev: no wrangler config yet; waiting"; sleep 10; exit 0; }
            # Prefer the project's own pinned wrangler when it has one.
            if [ -x node_modules/.bin/wrangler ]; then WR=node_modules/.bin/wrangler; else WR=wrangler; fi
            exec "$WR" dev --ip 0.0.0.0 --port ${devPort}
          '';

          startupHook = pkgs.writeTextDir "etc/nixenv-hooks.sh" ''
            nixenv_pre_ssh_start() {
              APP="''${NIXENV_APP_MOUNT:-/app}"
              mkdir -p "$APP/.nixenv"

              # ---- one-time scaffold --------------------------------------
              if [ -f "$APP/.nixenv/.cloudflare-scaffolded" ]; then
                # Existing project: make sure deps are present, then done.
                if [ -f "$APP/package.json" ] && [ ! -d "$APP/node_modules" ]; then
                  echo "nixenv/cloudflare: installing npm dependencies…"
                  ( cd "$APP" && npm install --no-audit --no-fund ) || \
                    echo "nixenv/cloudflare: npm install failed (egress? nixenv egress $NIXENV_PROJECT)"
                fi
                return 0
              fi

              # Don't touch a project that already has content (cloned repo).
              if [ -f "$APP/package.json" ] || [ -f "$APP/wrangler.toml" ] || [ -f "$APP/wrangler.jsonc" ]; then
                echo "nixenv/cloudflare: existing project detected — skipping scaffold"
                if [ ! -d "$APP/node_modules" ] && [ -f "$APP/package.json" ]; then
                  ( cd "$APP" && npm install --no-audit --no-fund ) || true
                fi
                touch "$APP/.nixenv/.cloudflare-scaffolded"
                return 0
              fi

              echo "nixenv/cloudflare: scaffolding a minimal Worker…"
              mkdir -p "$APP/src"
              cat > "$APP/wrangler.toml" <<'TOML'
            name = "@@PROJECT@@"
            main = "src/index.ts"
            compatibility_date = "2026-01-01"

            # Local dev only needs the lines above. Uncomment to use bindings —
            # `wrangler dev` emulates KV/D1/R2/queues locally (state under
            # .wrangler/state), no Cloudflare account required.
            # [[kv_namespaces]]
            # binding = "MY_KV"
            # id = "local"
            #
            # [[d1_databases]]
            # binding = "DB"
            # database_name = "@@PROJECT@@"
            # database_id = "local"
            TOML

              cat > "$APP/src/index.ts" <<'TS'
            export default {
              async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
                const url = new URL(request.url);
                if (url.pathname === "/health") {
                  return Response.json({ ok: true, worker: "@@PROJECT@@" });
                }
                return new Response(
                  `Hello from @@PROJECT@@ 👋\n\n` +
                  `Edit src/index.ts — wrangler reloads automatically.\n` +
                  `Public URL: https://@@PROJECT@@-${devPort}.@@DOMAIN@@/\n`,
                  { headers: { "content-type": "text/plain; charset=utf-8" } },
                );
              },
            } satisfies ExportedHandler<Env>;

            interface Env {
              // MY_KV: KVNamespace;
              // DB: D1Database;
            }
            TS

              cat > "$APP/package.json" <<'JSON'
            {
              "name": "@@PROJECT@@",
              "private": true,
              "type": "module",
              "scripts": {
                "dev": "wrangler dev --ip 0.0.0.0",
                "deploy": "wrangler deploy",
                "typecheck": "tsc --noEmit"
              }
            }
            JSON

              cat > "$APP/tsconfig.json" <<'JSON'
            {
              "compilerOptions": {
                "target": "es2022",
                "module": "es2022",
                "moduleResolution": "bundler",
                "lib": ["es2022"],
                "types": ["@cloudflare/workers-types"],
                "strict": true,
                "noEmit": true
              },
              "include": ["src/**/*.ts"]
            }
            JSON

              cat > "$APP/.gitignore" <<'GI'
            node_modules/
            .wrangler/
            .dev.vars
            GI

              touch "$APP/.nixenv/.cloudflare-scaffolded"
              echo "nixenv/cloudflare: ready → https://@@PROJECT@@-${devPort}.@@DOMAIN@@/"
              echo "nixenv/cloudflare: 'wrangler login' is only needed to deploy."
            }
          '';
        in
        {
          default = pkgs.buildEnv {
            name = "cloudflare-project";
            extraOutputsToInstall = [ "man" ];
            paths = [
              pkgs.nodejs_22          # node + npm/npx
              pkgs.wrangler           # pinned by this flake; a local
                                      # node_modules/.bin/wrangler wins if present
              # wrangler VENDORS its own typescript, so both packages ship
              # lib/node_modules/typescript/… — hiPrio picks a winner instead of
              # failing the build with "two given paths contain a conflicting
              # subpath". Drop this line entirely if you'd rather get `tsc` from
              # the project's own devDependencies.
              (pkgs.lib.hiPrio pkgs.typescript)
              pkgs.jq
              svWrangler              # → ~/.nixenv-sv/wrangler-dev, run by runit
              startupHook
            ];
          };
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in { default = pkgs.mkShell { packages = [ self.packages.${system}.default ]; }; });
    };
}
