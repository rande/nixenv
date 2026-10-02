---
id: TPL-12
title: "Verify a template by running it"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
---

# TPL-12: Verify a template by running it

## Rule

- Besides the unit test, a template change MUST be verified by running it in
  the dev project: `nixenv-docker init <p> --template=/app/templates/<name>.nix
  --yes && nixenv-docker run <p>`, then `sv status ~/.nixenv-sv/*`, the
  container log for ERROR/FATAL/WARN, an HTTP check on the declared port, and
  `nixenv-docker egress <p>`.

## Why

`assert_template` is textual: it can't see a `buildEnv` collision, a service
that logs errors, or a silent setup failure. A 2026-10 pass found one template
that didn't build, one half-failed setup, and errors in three others.

## How

See DEV-01 for the nested engines.
