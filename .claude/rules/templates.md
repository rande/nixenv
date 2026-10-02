---
paths:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
  - "nixenv.sh"
  - "examples/**"
  - "dev/flake.nix"
  - "templates/windmill.nix"
  - "tests/unit/18-template-windmill.sh"
---

# Templates rules (Writing project templates)

These rules are specified one per file under `specs/templates/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- TPL-01 A template is one file that becomes flake.nix: @../../specs/templates/001-template-format.md
- TPL-02 Template sources are pinned: @../../specs/templates/002-template-sources-pinned.md
- TPL-03 Declare services as files, never from the hook: @../../specs/templates/003-services-as-files.md
- TPL-04 Project files are created by the hook, marker-guarded: @../../specs/templates/004-app-files-from-hook.md
- TPL-05 Scratch dirs writable by app; generators assert their result: @../../specs/templates/005-writable-scratch.md
- TPL-06 nginx and php-fpm configs use literal paths: @../../specs/templates/006-no-env-in-nginx-phpfpm.md
- TPL-07 Nix indented strings: no bare quotes in comments, escape ${: @../../specs/templates/007-nix-indented-string-traps.md
- TPL-08 Dev servers bind 0.0.0.0 on the declared port: @../../specs/templates/008-bind-all-interfaces.md
- TPL-09 Resolve buildEnv collisions with hiPrio: @../../specs/templates/009-buildenv-collisions.md
- TPL-10 Services exec in the foreground and wait for dependencies: @../../specs/templates/010-service-dependencies.md
- TPL-11 Declare every host setup needs; a clean log proves nothing: @../../specs/templates/011-declare-egress-hosts.md
- TPL-12 Verify a template by running it: @../../specs/templates/012-verify-by-running.md
- TPL-13 Windmill template specifics: @../../specs/templates/013-windmill.md
