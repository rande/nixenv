---
id: TPL-06
title: "nginx and php-fpm configs use literal paths"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
  - "examples/**"
---

# TPL-06: nginx and php-fpm configs use literal paths

## Rule

- nginx and php-fpm configs MUST use literal `/home/app/...` paths, not
  `${HOME}`. Only `sv/*/run` scripts (shell) can use `$HOME`.
- nginx MUST be started with `-e /dev/stderr`.

## Why

Neither expands env vars in its config. nginx opens its compiled-in
`/var/log/nginx/error.log` before reading the config.

## How

The runtime user is always `app`.
