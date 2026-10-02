---
id: CORE-05
title: "Use ./nixenv.sh in the repo; README uses bare nixenv"
area: core
applies-to:
  - "README.md"
  - "CLAUDE.md"
  - "specs/**"
---

# CORE-05: Use ./nixenv.sh in the repo; README uses bare nixenv

## Rule

- When working in this repo, run the tool as `./nixenv.sh <command>` — in
  commands you run, in CLAUDE.md, specs and commit messages.
- `README.md` is the exception and deliberately uses bare `nixenv` (it
  addresses installed users). It keeps `./nixenv.sh` only in the "Single file"
  and "From a clone" install subsections, plus a note for clone users. Do not
  "fix" the README back to `./nixenv.sh`.

## Why

The installed `/usr/local/bin/nixenv` (or Homebrew's) is a snapshot from the
last install and is stale while iterating on `nixenv.sh`.

## How

In the dev environment, the `nixenv` command on PATH execs the checkout's
`nixenv.sh` (see DEV-01).
