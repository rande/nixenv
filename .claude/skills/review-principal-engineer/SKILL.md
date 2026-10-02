---
name: review-principal-engineer
description: Review a nixenv change as a principal engineer — design, maintainability, failure modes, migrations of users' existing state, tests and docs. Use when asked to review code, a diff, a branch or a PR in this repository, or before a release; pair it with review-security and review-linux-macos for a full review.
allowed-tools: Read, Grep, Glob, Bash
---

# Principal-engineer review for nixenv

You review changes to **nixenv**: one self-contained Bash script (`nixenv.sh`)
that manages per-project containers sharing a Nix store. Judge whether the
change is *right for this codebase*, not whether it would be fine somewhere else.

## Before you start

1. Read `specs/README.md`, then every spec whose `applies-to` matches a changed
   file. They record the invariants and the bugs that produced them; most review
   findings are violations of something written there.
2. Establish the scope: `git diff --stat <base>...HEAD` (or the files you were
   given). Read every changed hunk, then the *callers* of every changed function
   (`grep -n 'fn_name' nixenv.sh`) — breakage usually hides at a call site.
3. Run `./tests/run.sh` (unit, no Docker). A red suite is finding #1.

## What to check

**Invariants of this repo**
- Embedded files (`flake.nix`, entrypoint, home skeleton) change only inside
  their single-quoted heredocs in `materialize_context()`; no standalone copies
  appear in the repo (the dev flake lives in `dev/`, examples in `examples/`).
- The base flake gains no language runtime or runtime-needing LSP.
- Every container call goes through `"$ENGINE"`, image refs through `img`, names
  through the helpers (`app_volume`, `container_name`, `project_dir`, …).
- PATH order is set in four places that must agree.
- Anything that becomes an engine argument is an **array**, expanded guarded
  (`${a[@]+"${a[@]}"}`) — never an unquoted string of flags.

**Behaviour and failure modes**
- What happens on the second run? nixenv commands must be idempotent and must
  never clobber a user's hand edits (see how `write_host_ssh_config` migrates).
- What happens to users who already have state in `~/.nixenv/`? A change to a
  generated file needs a migration path or a warning; a change applied only at
  container creation must say "stop && run".
- Errors must be actionable: say what failed and the exact command that fixes it.
- Destructive paths (`delete`, `import --force`, volume wipes) confirm first,
  and `--yes` must not grant anything security-relevant.
- Prompts need a no-TTY path that neither hangs nor silently grants.

**Tests**
- New pure logic → a unit test in `tests/unit/NN-*.sh`; container behaviour →
  an integration test too. Tests that grep the source must pipe through
  `code_only`, or they match the explanatory comment instead of the code.
- A test that can't fail is a finding (patterns that never occur, literal `\n`
  in a `case` pattern, assertions after an unguarded `exit`).

**Docs and release**
- The matching `specs/` file added or updated for anything a future maintainer
  must know (the *why*); `tests/unit/39-specs.sh` passes.
- `README.md` uses bare `nixenv`; `DEVELOPING.md`/`RELEASING.md` still match reality.
- Help text (`usage`) lists new commands. Version/formula rules in `RELEASING.md`.

**Design**
- Is this the simplest change that works? Flag new knobs that nobody asked for,
  duplicated logic (one sha256 implementation, one `seed_project_home`, …), and
  abstractions with a single caller.

## How to report

Lead with a one-paragraph verdict (ship / ship after fixes / rethink). Then
findings, most severe first:

```
[blocker|major|minor|nit] <title>
  where:    nixenv.sh:<line> (function)
  problem:  what goes wrong, for whom, when — concrete scenario
  evidence: the code, a command you ran, or a failing test
  fix:      the smallest change that resolves it (+ the test that proves it)
```

Only report what you verified. If you're unsure, say what you'd run to find out.
Don't pad with praise or style preferences the codebase doesn't already follow.
