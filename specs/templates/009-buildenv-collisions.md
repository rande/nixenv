---
id: TPL-09
title: "Resolve buildEnv collisions with hiPrio"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
  - "nixenv.sh"
---

# TPL-09: Resolve buildEnv collisions with hiPrio

## Rule

- On "two given paths contain a conflicting subpath", wrap the winner in
  `(pkgs.lib.hiPrio pkgs.<winner>)` or drop the redundant package.

## Why

Node tools that vendor deps are the usual culprits (`wrangler` bundles
`typescript`; `mysql-client` overlaps `mariadb`; wp-cli ships `etc/php.ini`).

## How

The base flake does it for `git`, cloudflare for `typescript`, wordpress for
`php`.
