---
id: TEST-03
title: "Grep source through code_only"
area: testing
applies-to:
  - "tests/**"
---

# TEST-03: Grep source through code_only

## Rule

- When a test greps source for a pattern that the code's own comments plausibly
  mention, pipe it through `code_only` (strips `#` comments) first.

## Why

This repo documents each trap in a comment beside the fix, so a naive grep
matches the warning instead of the code. That broke a guard three times (the
bare `''` rule, `[ -t 2 ] &&`, an `ensure_volumes` ordering check).

## How

`code_only` lives in `tests/lib.sh`.
