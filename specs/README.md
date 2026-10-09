# nixenv specifications

One rule per file. These files are the source of truth for how nixenv
must behave and why; `CLAUDE.md` and `AGENTS.md` only point here.

## Format

```markdown
---
id: EGR-03                      # <AREA>-<NN>, unique, never reused
title: "Refused names are never resolved"
area: egress                    # = the folder name
security: SEC-05                # optional: the security finding it closes
applies-to:                     # globs of the files this rule governs
  - "nixenv.sh"
enforced-by:                    # optional: tests that fail when it is broken
  - tests/unit/08-egress-config.sh
---

# EGR-03: Refused names are never resolved
## Rule   — what MUST / MUST NOT hold (testable statements)
## Why    — the incident or reasoning behind it
## How    — where and how it is implemented
```

## Working with specs

- Before changing code, read the specs whose `applies-to` matches the files
  you touch (Claude Code loads them automatically via `.claude/rules/`).
- A behaviour change updates its spec in the same commit; a new rule gets a
  new file with the next free number in its area, plus a line in the index
  below and in `.claude/rules/<area>.md`.
- Prefer naming the test in `enforced-by`; an unenforced rule is a wish.
- `tests/unit/39-specs.sh` checks the frontmatter, unique ids, that every
  `enforced-by` path exists, and that each spec is indexed here and in
  `.claude/rules/`.

## Index

### Core — How the script is built and run

- [CORE-01](core/001-single-file-source-of-truth.md) nixenv.sh is self-contained
- [CORE-02](core/002-embedded-heredocs.md) Embedded heredocs: quoted, unique delimiters, deliberate escapes
- [CORE-03](core/003-engine-abstraction.md) Docker and podman through $ENGINE
- [CORE-04](core/004-shell-portability.md) Bash 3.2 for nixenv.sh, POSIX sh for the entrypoints
- [CORE-05](core/005-invoke-checkout-script.md) Use ./nixenv.sh in the repo; README uses bare nixenv
- [CORE-06](core/006-prefix-naming.md) All engine-side names derive from CONTAINER_PREFIX
- [CORE-07](core/007-early-dispatch.md) help, version, install run before materialize_context
- [CORE-08](core/008-user-data-safety.md) Never commit or casually destroy ~/.nixenv/projects
- [CORE-09](core/009-global-config-file.md) ~/.nixenv/config holds global settings, parsed and never sourced

### Toolchain — The shared Nix store, project flakes, PATH

- [TOOL-01](toolchain/001-base-flake-no-runtimes.md) The base flake ships no language runtimes
- [TOOL-02](toolchain/002-shared-profile-reset.md) build resets the shared profile before installing
- [TOOL-03](toolchain/003-zmx-pinned-prebuilt.md) zmx is a pinned prebuilt binary (SEC-09)
- [TOOL-04](toolchain/004-project-flakes-untrusted.md) Project flakes are untrusted (SEC-04)
- [TOOL-05](toolchain/005-flake-dir-remembered.md) build --dir is remembered per project
- [TOOL-06](toolchain/006-path-order.md) PATH order: ~/.local/bin, project profile, base
- [TOOL-07](toolchain/007-github-token.md) Optional GitHub token for flake inputs
- [TOOL-08](toolchain/008-claude-cli.md) Claude CLI from nixpkgs-unstable on the shared profile

### Runtime — Project containers, volumes, entrypoint, services

- [RUN-01](runtime/001-non-root-container.md) Project containers run entirely non-root
- [RUN-02](runtime/002-runtime-hardening.md) Runtime hardening on every nixenv container (SEC-07)
- [RUN-03](runtime/003-named-volumes-ownership.md) Named volumes, owned by your uid
- [RUN-04](runtime/004-app-mount-path.md) Per-project app mount path
- [RUN-05](runtime/005-entrypoint-modes.md) Entrypoint: command mode and service mode
- [RUN-06](runtime/006-project-services.md) Project services: runit dirs refreshed each boot
- [RUN-07](runtime/007-startup-hooks.md) Startup hooks are the only way to run project code at start
- [RUN-08](runtime/008-extra-parameters.md) Extra engine flags come from <project>/extra-parameters
- [RUN-09](runtime/009-published-ports.md) Extra published ports in <project>/ports
- [RUN-10](runtime/010-etc-hosts.md) Custom /etc/hosts is rebuilt by the entrypoint
- [RUN-11](runtime/011-git-identity-credentials.md) Per-project git identity and https credentials
- [RUN-12](runtime/012-claude-isolation.md) Claude: only the login is shared between projects (SEC-03)
- [RUN-13](runtime/013-bare-helpers-no-store-tools.md) Bare RUNTIME_IMAGE helpers have only Debian tools
- [RUN-14](runtime/014-sync-home.md) sync-home refreshes dotfiles into an existing home volume
- [RUN-15](runtime/015-run-stop-lifecycle.md) run, shell, ssh, stop and logs lifecycle

### SSH — Key-only login, pinned host key, zmx sessions

- [SSH-01](ssh/001-key-only.md) Container sshd accepts only the host-generated project key (SEC-02)
- [SSH-02](ssh/002-host-key-pinning.md) The container host key is pinned (SEC-10)
- [SSH-03](ssh/003-ssh-config-zmx.md) Host ssh config with zmx sessions

### Networking — Shared reverse proxy, TLS, cross-project isolation

- [NET-01](networking/001-shared-reverse-proxy.md) One shared Caddy reverse proxy for all projects
- [NET-02](networking/002-proxy-tls-mkcert.md) TLS: mkcert only if present, never a surprise prompt
- [NET-03](networking/003-public-url-from-inside.md) Public URLs work from inside a container
- [NET-04](networking/004-cross-project-isolation.md) Restricted projects cannot reach other projects through the proxy (SEC-06)
- [NET-05](networking/005-project-dashboard.md) ps and the dashboard: probed from the host, read-only, no secrets

### Egress — Restricted-by-default egress through squid

- [EGR-01](egress/001-restricted-by-default.md) Egress restriction is on by default
- [EGR-02](egress/002-allowlist.md) allowed_hosts: validated, exact by default
- [EGR-03](egress/003-refused-names-never-resolved.md) Refused names are never resolved (SEC-05)
- [EGR-04](egress/004-ssh-hosts.md) Port 22 only to declared git hosts (SEC-11)
- [EGR-05](egress/005-egress-container.md) squid runs in its own egress container
- [EGR-06](egress/006-start-ordering.md) Restricted run: proxy before container, refresh after
- [EGR-07](egress/007-egress-address-migration.md) Migrate files that recorded an old egress address

### Capture — mitmproxy traffic capture behind squid

- [CAP-01](capture/001-behind-squid.md) mitmproxy runs behind squid, never instead of it
- [CAP-02](capture/002-ingress-capture.md) Ingress capture routed by Caddy through mitmproxy
- [CAP-03](capture/003-addon-safety.md) Capture addon: tagging, storage, rebinding, streaming
- [CAP-04](capture/004-capture-ui.md) mitmweb UI only through Caddy, with a token
- [CAP-05](capture/005-capture-ca-trust.md) Capture CA trust is explicit and sticky until untrust

### Deploy — Throwaway deploy container with the forwarded agent

- [DEP-01](deploy/001-throwaway-deploy-container.md) deploy: a throwaway container holding the forwarded agent
- [DEP-02](deploy/002-deploy-ssh-transport.md) deploy connects over ssh carried by engine exec
- [DEP-03](deploy/003-deploy-egress.md) deploy egress: allowed_hosts + deploy_hosts on its own network
- [DEP-04](deploy/004-deploy-host-files.md) deploy reads git and ssh settings from host-side files only
- [DEP-05](deploy/005-deploy-state-volume.md) deploy keeps state in its own volume, created on first use

### Export / import — Moving and backing up projects

- [EXP-01](export/001-archive-format.md) Export archive format
- [EXP-02](export/002-project-files-travel.md) The whole project dir travels, except what is regenerated
- [EXP-03](export/003-regenerated-on-import.md) Machine-specific state is regenerated on import
- [EXP-04](export/004-imported-meta-untrusted.md) Imported meta files are untrusted (SEC-01)
- [EXP-05](export/005-home-volume-opt-in.md) The home volume is opt-in
- [EXP-06](export/006-git-token-in-app-volume.md) Tokens embedded in the app volume are refused
- [EXP-07](export/007-progress-reporting.md) Progress meter only for export/import tars

### Templates — Writing project templates

- [TPL-01](templates/001-template-format.md) A template is one file that becomes flake.nix
- [TPL-02](templates/002-template-sources-pinned.md) Template sources are pinned (SEC-08)
- [TPL-03](templates/003-services-as-files.md) Declare services as files, never from the hook
- [TPL-04](templates/004-app-files-from-hook.md) Project files are created by the hook, marker-guarded
- [TPL-05](templates/005-writable-scratch.md) Scratch dirs writable by app; generators assert their result
- [TPL-06](templates/006-no-env-in-nginx-phpfpm.md) nginx and php-fpm configs use literal paths
- [TPL-07](templates/007-nix-indented-string-traps.md) Nix indented strings: no bare quotes in comments, escape ${
- [TPL-08](templates/008-bind-all-interfaces.md) Dev servers bind 0.0.0.0 on the declared port
- [TPL-09](templates/009-buildenv-collisions.md) Resolve buildEnv collisions with hiPrio
- [TPL-10](templates/010-service-dependencies.md) Services exec in the foreground and wait for dependencies
- [TPL-11](templates/011-declare-egress-hosts.md) Declare every host setup needs; a clean log proves nothing
- [TPL-12](templates/012-verify-by-running.md) Verify a template by running it
- [TPL-13](templates/013-windmill.md) Windmill template specifics
- [TPL-14](templates/014-model-flake-in-sync.md) templates/flake.nix and the dashboard's model flake stay identical

### Release — Versioning, Homebrew, release script, CI

- [REL-01](release/001-version-and-license.md) NIXENV_VERSION and the GPL licence
- [REL-02](release/002-releasing-runbook.md) RELEASING.md is the one release runbook
- [REL-03](release/003-homebrew-formula.md) Homebrew formula: no dependencies, may lag the version
- [REL-04](release/004-release-script.md) release.sh drives a release end to end, offline-testable
- [REL-05](release/005-ci-workflows.md) CI and release workflows

### Dev environment — Developing nixenv inside nixenv

- [DEV-01](dev/001-nested-dev-environment.md) Developing nixenv inside nixenv

### Testing — Test suite and harness

- [TEST-01](testing/001-unit-suite-always.md) Run the unit suite after every change
- [TEST-02](testing/002-test-harness.md) Test layout and harness
- [TEST-03](testing/003-code-only-grep.md) Grep source through code_only
- [TEST-04](testing/004-template-contract.md) Shared template contract
