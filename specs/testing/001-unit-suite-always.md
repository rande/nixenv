---
id: TEST-01
title: "Run the unit suite after every change"
area: testing
applies-to:
  - "nixenv.sh"
  - "tests/**"
  - "templates/**"
---

# TEST-01: Run the unit suite after every change

## Rule

- After editing `nixenv.sh`, ALWAYS run `./tests/run.sh` (unit, no engine) and
  keep it green.
- New feature: a unit test for its pure logic, and an integration test file if
  it touches containers.

## Why

Most regressions here are silent at runtime.

## How

Quick checks: `bash -n nixenv.sh`; `CONTEXT_DIR=/tmp/ctx ./nixenv.sh status`;
`sh -n /tmp/ctx/entrypoint.sh`.
