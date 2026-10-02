---
id: TPL-08
title: "Dev servers bind 0.0.0.0 on the declared port"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
enforced-by:
  - tests/lib-template.sh
---

# TPL-08: Dev servers bind 0.0.0.0 on the declared port

## Rule

- Dev servers MUST bind `0.0.0.0` (`--host`, `--ip`, `HOST=`), never localhost.
- The declared `# nixenv:port` MUST match the port the stack serves.

## Why

The reverse proxy is a different container.

## How

`assert_template` checks the binding.
