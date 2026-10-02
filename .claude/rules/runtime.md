---
paths:
  - "nixenv.sh"
---

# Runtime rules (Project containers, volumes, entrypoint, services)

These rules are specified one per file under `specs/runtime/`. Read and
follow the relevant ones before changing the files they govern; if a
change alters a rule, update its spec in the same commit.

- RUN-01 Project containers run entirely non-root: @../../specs/runtime/001-non-root-container.md
- RUN-02 Runtime hardening on every nixenv container: @../../specs/runtime/002-runtime-hardening.md
- RUN-03 Named volumes, owned by your uid: @../../specs/runtime/003-named-volumes-ownership.md
- RUN-04 Per-project app mount path: @../../specs/runtime/004-app-mount-path.md
- RUN-05 Entrypoint: command mode and service mode: @../../specs/runtime/005-entrypoint-modes.md
- RUN-06 Project services: runit dirs refreshed each boot: @../../specs/runtime/006-project-services.md
- RUN-07 Startup hooks are the only way to run project code at start: @../../specs/runtime/007-startup-hooks.md
- RUN-08 Extra engine flags come from <project>/extra-parameters: @../../specs/runtime/008-extra-parameters.md
- RUN-09 Extra published ports in <project>/ports: @../../specs/runtime/009-published-ports.md
- RUN-10 Custom /etc/hosts is rebuilt by the entrypoint: @../../specs/runtime/010-etc-hosts.md
- RUN-11 Per-project git identity and https credentials: @../../specs/runtime/011-git-identity-credentials.md
- RUN-12 Claude: only the login is shared between projects: @../../specs/runtime/012-claude-isolation.md
- RUN-13 Bare RUNTIME_IMAGE helpers have only Debian tools: @../../specs/runtime/013-bare-helpers-no-store-tools.md
- RUN-14 sync-home refreshes dotfiles into an existing home volume: @../../specs/runtime/014-sync-home.md
- RUN-15 run, shell, ssh, stop and logs lifecycle: @../../specs/runtime/015-run-stop-lifecycle.md
