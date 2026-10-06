---
id: TPL-14
title: "templates/flake.nix and the dashboard's model flake stay identical"
area: templates
applies-to:
  - "templates/flake.nix"
  - "nixenv.sh"
enforced-by:
  - tests/unit/41-dashboard.sh
---

# TPL-14: templates/flake.nix and the dashboard's model flake stay identical

## Rule

- `templates/flake.nix` and `dashboard_model_flake` in `nixenv.sh` (the model
  shown, collapsed, in the dashboard's *03 · New project* section) MUST always
  be byte-for-byte identical.
- A change to one is made to the other IN THE SAME COMMIT. Never edit the
  escaped copy in the generated `index.html`; the page escapes the heredoc at
  write time (`html_escape`).

## Why

`nixenv.sh` is self-contained (CORE-01): a single-file install has no
`templates/` folder, so the dashboard cannot read the file at runtime and
carries a copy. Two copies drift; users would copy a model from the page that
differs from the one in the repo.

## How

`tests/unit/41-dashboard.sh` compares the `cksum` of `dashboard_model_flake`
with `templates/flake.nix`, and of the page's unescaped `<pre id="model-flake">`
with the same file. To update: edit `templates/flake.nix`, then replace the body
of the `NIXENV_MODEL_FLAKE` heredoc with it (quoted delimiter, CORE-02).
