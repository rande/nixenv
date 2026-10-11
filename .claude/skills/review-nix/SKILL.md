---
name: review-nix
description: Nix expert review of nixenv — the embedded base flake, project flakes and templates, the nix builder invocation (NIX_CONFIG, sandboxing, substituters, trust), profiles, store volume, gc and pinning. Use when asked for a Nix review, when a change touches flake.nix (embedded NIXENV_FLAKE, templates/*.nix, dev/flake.nix, examples/), run_builder/nix_config*, cmd_build*/cmd_update/cmd_gc, or before bumping nixpkgs; pair it with review-security for trust questions.
allowed-tools: Read, Grep, Glob, Bash
---

# Nix review for nixenv

You review how nixenv USES Nix as a senior Nix engineer would: correctness,
reproducibility, purity, closure size, store hygiene, and the trust boundary
between nixenv's own flake and untrusted project flakes. Read-only unless the
user explicitly asks for changes.

## How Nix is used here (read these first)

| Where | What |
|---|---|
| `nixenv.sh` → `materialize_context`, heredoc `NIXENV_FLAKE` | The **base flake**: shell/editor/CLI toolbox installed into the shared profile `/nix/var/nix/profiles/shared` (TOOL-01, TOOL-03, TOOL-08). `flake.lock` lives in `$CONTEXT_DIR`, never written by the script. |
| `run_builder`, `builder_priv`, `ensure_builder_usable`, `protect_builder_toolchain` | The `nixos/nix` builder container (`BUILDER_IMAGE`) that runs every nix command against the `NIX_VOLUME` store volume. |
| `nix_config` / `nix_config_project` | `NIX_CONFIG` for trusted (base) vs untrusted (project) builds: `accept-flake-config`, sandbox, GitHub `access-tokens` (TOOL-04, TOOL-07). |
| `cmd_build`, `cmd_build_project`, `project_profile` | Profile reset + `nix profile install` (TOOL-02); project flakes copied to `<project>/flake/`, installed as `path:/flake#$PROJECT_ATTR` into `proj-<name>` (TOOL-04, TOOL-05). |
| `cmd_update`, `cmd_gc` | Lock bumps; garbage collection with live containers referencing store paths. |
| `templates/*.nix`, `templates/flake.nix` (= `dashboard_model_flake`, TPL-14) | Project templates: `writeTextDir` services/hooks (TPL-03), indented-string traps (TPL-07), `hiPrio` collisions (TPL-09), windmill wrapper surgery (TPL-13). |
| `dev/flake.nix`, `examples/hello/flake.nix` | Project flakes for the nested dev environment (DEV-01) and the smoke test. |
| Runtime | Containers mount the store `:ro`; PATH = `~/.local/bin` → project profile → shared profile (TOOL-06); the entrypoint reads `$PROFILE/bin/*`, `etc/nixenv-hooks.sh`, `sv/*/run` from profiles (RUN-06/07). |

Specs to respect: `specs/toolchain/*`, `specs/templates/*`, `specs/dev/001-*`,
`specs/core/001-002` (heredoc embedding). Don't re-report documented, accepted
limits (e.g. project builds usually fall back to unsandboxed, TOOL-04).

## Checklist

**Flakes and pinning**
- Every input pinned through `flake.lock`; no `builtins.fetchTarball`/
  `fetchGit` without a hash, no `<nixpkgs>`/`NIX_PATH`, no `--impure` (TOOL-03).
- `inputs.*.follows` used where two inputs would otherwise pull two nixpkgs
  (closure size, evaluation time).
- `systems` coverage matches what is advertised (x86_64/aarch64 linux; darwin
  only if anything evaluates there); per-system hashes complete.
- Overlays / `config.allowUnfree` scoped and justified (e.g. `claude-code`).

**Derivations**
- `fetchurl`/prebuilt binaries: hash pinned, version and URL in one place,
  static or `autoPatchelfHook` correct, licence/`meta` sane.
- `buildEnv` / `symlinkJoin`: collisions resolved deliberately (`hiPrio`,
  `ignoreCollisions` is a smell), `pathsToLink` not dropping needed dirs
  (`share/`, `etc/`, `libexec/`).
- `writeShellScript(Bin)` vs `writeTextDir`: shebang, executable bit, runtime
  deps referenced by store path rather than relying on PATH.
- Indented strings: `''${…}` escapes, no bare `''` in comments, Nix vs shell
  interpolation intended (TPL-07); `lib.escapeShellArg` for interpolated values.
- Things that only work by accident: IFD, `builtins.currentSystem`, reading
  `$HOME`, network in builds.

**Builder, store and trust**
- Base vs project separation holds: projects never get `--accept-flake-config`,
  the GitHub token, or a substituter/trusted-public-key they chose (TOOL-04).
- `NIX_CONFIG` contents: no newline injection, `sandbox`/`sandbox-fallback`,
  `experimental-features`, `max-jobs`/`cores` sensible, substituters and keys
  explicit.
- Profiles: reset semantics (TOOL-02), generation links, gc roots for every
  profile containers depend on; `gc` can't delete a running container's
  closure without warning.
- Store volume mounted read-only everywhere except the builder; ownership and
  `nix-daemon`-less single-user assumptions stated.
- Builder image pinned (`nixos/nix:<version>`) and compatible with the lock's
  nix features (lockfile version, `path:` flakes, `profile` v2 manifest).

**Reproducibility and UX**
- Same lock → same closure on another machine; nothing reads the host.
- Rebuild cost: what invalidates the cache (copying the whole `--dir`, `self`
  in the source, timestamps).
- Error paths: rate limits, 401s, hash mismatches surface with a fix
  (`run_builder`'s explanations).

## Method

1. Read the spec(s), then the code: extract the embedded flake with
   `CONTEXT_DIR=$(mktemp -d) ./nixenv.sh status` (writes `flake.nix`) or read
   the heredoc directly.
2. If `nix` is available, verify instead of asserting: `nix flake check`,
   `nix flake metadata`, `nix eval .#… --raw`, `nix path-info -rSh` for closure
   size, `nix-instantiate --parse` for template syntax. No network? Say which
   claims are unverified.
3. Never modify files during a review unless asked.

## How to report

```
[high|medium|low|nit] <title>
  where:   <file>:<line> (function / attribute)
  issue:   what is wrong and the concrete consequence (build break, impurity,
           closure bloat, trust bypass, stale profile…)
  fix:     the Nix change, and how to verify it (command or test)
```

Group by area (base flake, builder/trust, profiles/gc, templates, dev).
Finish with what is done well and the top three actions.
