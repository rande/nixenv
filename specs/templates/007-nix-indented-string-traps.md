---
id: TPL-07
title: "Nix indented strings: no bare quotes in comments, escape ${"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
  - "dev/flake.nix"
  - "examples/**"
enforced-by:
  - tests/lib-template.sh
---

# TPL-07: Nix indented strings: no bare quotes in comments, escape ${

## Rule

- Never write a bare `''` in a comment that sits INSIDE an indented string; say
  "indented string" or escape it as `'''`.
- Escape shell `${…}` as `''${…}` inside indented strings (a bare `$VAR` is
  literal). JS/TS template literals too: never a backtick directly followed by
  `${`.
- In a double-quoted Nix string, a literal `${` is escaped `\${`.

## Why

`''` both opens and closes such a string; Nix then reports a syntax error at the
comment, far from anything that looks wrong, and two of them cancel out.
directus-astro shipped `` `${base}/x` `` and failed with "undefined variable".

## How

`assert_template` rejects both patterns; top-level comments at column 0 are
fine.
