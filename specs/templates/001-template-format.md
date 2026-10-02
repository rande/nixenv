---
id: TPL-01
title: "A template is one file that becomes flake.nix"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
  - "nixenv.sh"
enforced-by:
  - tests/unit/13-template-machinery.sh
  - tests/lib-template.sh
---

# TPL-01: A template is one file that becomes flake.nix

## Rule

- `init --template=<name|url|path>`; mutually exclusive with a git URL; confirms
  first unless `--yes`.
- Metadata is read from leading `# nixenv:<key> <value>` comments
  (`description`, `port`, `allow`, `app-path`) BEFORE the build; the header also
  shows the `init` command.
- Only `@@PROJECT@@`, `@@APP_MOUNT@@`, `@@DOMAIN@@`, `@@PORT@@` are substituted.
  `install_template` writes `flake.nix` into the app volume (never clobbers an
  existing one); `init` then forces a project build.
- Every new template gets a `tests/unit/1N-template-<name>.sh` using
  `assert_template`.

## Why

Declared hosts/app-path feed the normal init flow before anything builds.

## How

Shipped: `wordpress`, `cloudflare`, `symfony`, `headlesscms-directus-astro`,
`windmill`.
