---
id: TPL-02
title: "Template sources are pinned"
area: templates
security: SEC-08
applies-to:
  - "nixenv.sh"
enforced-by:
  - tests/unit/13-template-machinery.sh
---

# TPL-02: Template sources are pinned

## Rule

- With `TEMPLATE_BASE` unset: `file://$SCRIPT_DIR/templates` (clone), else
  `file://$SCRIPT_DIR/../share/nixenv/templates` (brew pkgshare), else
  `…/rande/nixenv/v$NIXENV_VERSION/templates` — never `main`.
- `file://` is read directly (no curl); `http://` is refused unless
  `NIXENV_ALLOW_INSECURE_TEMPLATES=1`; a fetched template's sha256 is logged.

## Why

A template becomes a flake that runs code; `main` can change under a released
version. Paths can contain spaces.

## How

`resolve_template` handles paths, URLs and short names (cached in
`~/.nixenv/templates/`).
