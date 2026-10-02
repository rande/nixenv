---
id: TPL-13
title: "Windmill template specifics"
area: templates
applies-to:
  - "templates/windmill.nix"
  - "tests/unit/18-template-windmill.sh"
enforced-by:
  - tests/unit/18-template-windmill.sh
---

# TPL-13: Windmill template specifics

## Rule

- Its hook only seeds a README, `.gitignore`, an empty `workspaces/` and the
  `windmill_user`/`windmill_admin` roles; it MUST NEVER run `wmill sync`.
- `jobPython = python311` (copied wrapper with the python swapped;
  `INSTANCE_PYTHON_VERSION` pinned to match); `DISABLE_EMBEDDING=true`; workers
  wait for the server's `/api/version`; the first-run hook migrates once against
  a setup-only postgres, logging to `/tmp/pg-setup.log`.
- Opt-in `useUpstreamBinary` (fetchurl + `autoPatchelfHook`, x86_64 only).

## Why

Scripts/flows live in PostgreSQL; `wmill sync` is stateless and destructive in
both directions and scoped to cwd + workspace (one dir per workspace). Workers
preinstall Windmill's default 3.11, so any other nix-fixed `PYTHON_PATH` errors
on every start. The embedding model comes from huggingface.co. nixpkgs lags
upstream by ~200 releases.

## How

Replaces upstream's docker-compose with runit services: `windmill-server`, two
worker groups and postgres (one binary embeds the frontend). `windmillNixpkgs`
copies nixpkgs' wrapper with the python swapped (no rebuild). The `wmill` CLI is wrapped from JSR through the deno in windmill's closure. The
build fails if nixpkgs' wrapper changes shape.
