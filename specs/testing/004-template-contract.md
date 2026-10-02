---
id: TEST-04
title: "Shared template contract"
area: testing
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
---

# TEST-04: Shared template contract

## Rule

- `tests/lib-template.sh`'s `assert_template <name>` encodes the template rules
  (metadata valid, hook present, services as files, markers, placeholders,
  0.0.0.0 binding, Nix string traps). Every template has a unit test calling it.

## Why

Template mistakes fail silently at runtime.

## How

It is textual; TPL-12 covers what it can't see.
