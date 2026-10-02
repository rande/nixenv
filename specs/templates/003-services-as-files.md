---
id: TPL-03
title: "Declare services as files, never from the hook"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
enforced-by:
  - tests/lib-template.sh
---

# TPL-03: Declare services as files, never from the hook

## Rule

- Template services MUST be declared with `pkgs.writeTextDir "sv/<name>/run"`;
  never written by the hook with `cat > … <<'SV'` inside a Nix indented string.

## Why

Nix strips the minimum common indentation; one stray line changes it, the
heredoc terminator ends up indented, the heredoc never closes, the hook becomes
invalid shell — and the entrypoint (tolerant by design) continues with NO
services.

## How

The entrypoint copies `sv/*` from the profile into `$SVROOT` each boot (RUN-06).
