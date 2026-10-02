# AGENTS.md

Guidance for any coding agent (and human) working in this repository.

## What this is

A local container dev-environment tool. `nixenv.sh` provisions a shared Nix
store inside a standalone container volume and runs per-project
`debian:stable-slim` containers that mount that store read-only: fast,
disposable project containers that all share one pinned toolchain. Works with
docker or podman.

`nixenv.sh` is **self-contained**: the base `flake.nix`, the container
entrypoints and the home skeleton are heredocs inside it, written to
`~/.nixenv/context` on every run. Edit them there, never as standalone files.

## The rules live in `specs/`

Every behaviour and invariant is specified **one rule per file** in
[`specs/`](specs/README.md) — Rule (what must hold), Why (the incident behind
it), How (where it is implemented), plus the tests that enforce it.

Before changing a file, read the specs whose `applies-to` globs match it (the
index in `specs/README.md` lists them by area). If your change alters a rule,
update that spec in the same commit; a new rule gets a new file. Several rules
look arbitrary until you read their *Why* — they come from bugs that shipped.

Claude Code loads the relevant specs automatically through `.claude/rules/`.

## Working in this repo

- Run the tool as `./nixenv.sh <command>`, never the installed `nixenv`
  (stale snapshot). `README.md` deliberately uses bare `nixenv` (CORE-05).
- `nixenv.sh` must run on macOS Bash 3.2; generated entrypoints are POSIX sh
  (CORE-04). Every container call goes through `"$ENGINE"` (CORE-03).
- Never commit or casually destroy `~/.nixenv/projects/` (CORE-08).
- Developing nixenv inside a nixenv project: see `DEVELOPING.md` and DEV-01.
- Releasing: `RELEASING.md` (REL-02).
- Reviews: `.claude/skills/` has principal-engineer, security and Linux/macOS
  review skills; ask for "a full review of this branch" to apply all three.

## Verifying changes

After editing `nixenv.sh`, always run the unit suite (fast, no engine):

```sh
./tests/run.sh                    # unit tests — must stay green
./tests/run.sh integration        # needs a real engine (dedicated nxt-* env)
```

Quick checks without the suite:

```sh
bash -n nixenv.sh
CONTEXT_DIR=/tmp/ctx ./nixenv.sh status   # materialise embedded files
sh -n /tmp/ctx/entrypoint.sh
```

Test conventions are TEST-01…04. `./nixenv.sh --help` and `README.md` document
every command.
